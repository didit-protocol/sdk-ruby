# frozen_string_literal: true

require "json"

module DiditCodegen
  HTTP_METHODS = %w[get put post delete patch head options].freeze
  AUTH_VALUES = %w[api_key account_token none device_token public].freeze
  SDK_KEYS = %w[resource method auth server scope].freeze
  APPLICATION_PREFIX = "/v3/organization/{organization_id}/application/{application_id}/"

  # The x-didit-sdk naming of one operation (docs/DESIGN.md section 4).
  # +method+ mirrors the x-didit-sdk key, so it hides Struct#method on purpose.
  SdkNaming = Struct.new(:resource, :method, :auth, :server, :scope, keyword_init: true) do # rubocop:disable Lint/StructNewOverride
    def self.parse(where, raw)
      raise Error, "#{where}: x-didit-sdk must be an object." unless raw.is_a?(Hash)

      unknown = raw.keys - SDK_KEYS
      raise Error, "#{where}: unknown x-didit-sdk keys #{unknown.sort.inspect}." unless unknown.empty?

      %w[resource method auth server].each do |key|
        raise Error, "#{where}: x-didit-sdk is missing #{key.inspect}." unless raw.key?(key)
      end
      validate(where, raw)
      new(resource: raw["resource"], method: raw["method"], auth: raw["auth"], server: raw["server"],
          scope: raw["scope"])
    end

    def self.validate(where, raw)
      resource = raw["resource"]
      unless resource.is_a?(String) && resource.split(".", -1).all? { |s| s.match?(/\A[a-z][a-z0-9_]*\z/) }
        raise Error, "#{where}: resource #{resource.inspect} must be a dot path of snake_case names."
      end
      unless raw["method"].is_a?(String) && raw["method"].match?(/\A[a-z][a-z0-9_]*\z/)
        raise Error, "#{where}: method #{raw["method"].inspect} must be a snake_case name."
      end
      unless AUTH_VALUES.include?(raw["auth"])
        raise Error, "#{where}: auth #{raw["auth"].inspect} must be one of #{AUTH_VALUES.sort.join(", ")}."
      end
      raise Error, "#{where}: server must be true or false." unless [true, false].include?(raw["server"])
      return if raw["scope"].nil? || raw["scope"] == "application"

      raise Error, "#{where}: scope must be \"application\" when present."
    end

    def to_json_hash
      out = { "auth" => auth, "method" => method, "resource" => resource, "server" => server }
      out["scope"] = scope if scope
      out
    end
  end

  # One OpenAPI document: "verification" or "account".
  class Document
    attr_reader :name, :doc

    def initialize(name, doc)
      @name = name
      @doc = doc
    end

    # Follows $refs until a non-reference node.
    def resolve(node)
      seen = []
      while node.is_a?(Hash) && node.key?("$ref")
        ref = node["$ref"]
        raise Error, "#{name}: circular $ref #{ref}." if seen.include?(ref)

        seen << ref
        node = pointer(ref)
      end
      node
    end

    def pointer(ref)
      raise Error, "#{name}: only local $refs are supported, got #{ref}." unless ref.start_with?("#/")

      ref[2..].split("/").reduce(doc) do |cur, part|
        part = part.gsub("~1", "/").gsub("~0", "~")
        value = cur.is_a?(Hash) ? cur[part] : nil
        raise Error, "#{name}: unresolvable $ref #{ref}." if value.nil?

        value
      end
    end

    def components
      doc.dig("components", "schemas") || {}
    end
  end

  # One API operation with its SDK naming.
  Operation = Struct.new(
    :key, :api, :http_method, :path, :op, :document, :sdk, :deprecated, :deprecation_note, :parameters,
    keyword_init: true
  ) do
    def operation_id
      (op["operationId"] || key).to_s
    end

    def server?
      sdk.server
    end
  end

  # Everything the generator reads from openapi/.
  class Spec
    attr_reader :documents, :operations

    def self.load(openapi_dir)
      read = ->(file) { JSON.parse(File.read(File.join(openapi_dir, file), encoding: "UTF-8")) }
      documents = {
        "verification" => Document.new("verification", read.call("verification.json")),
        "account" => Document.new("account", read.call("account.json"))
      }
      overlay = read.call("overlay.json").fetch("operations", {})
      deprecated_file = File.join(openapi_dir, "deprecated-operations.json")
      deprecated = File.exist?(deprecated_file) ? read.call("deprecated-operations.json").fetch("methods", {}) : {}
      new(documents, overlay, deprecated)
    end

    def initialize(documents, overlay, deprecated)
      @documents = documents
      @operations = []
      seen = []
      missing = []
      documents.each do |api, document|
        (document.doc["paths"] || {}).each do |path, item|
          item = document.resolve(item)
          HTTP_METHODS.each do |http_method|
            op = item[http_method] or next
            key = Spec.key(api, http_method, path)
            seen << key
            raw = op.key?("x-didit-sdk") ? op["x-didit-sdk"] : overlay[key]
            if raw.nil?
              missing << "#{key} (operationId #{op["operationId"] || "-"})"
              next
            end
            @operations << Operation.new(
              key: key, api: api, http_method: http_method, path: path, op: op, document: document,
              sdk: SdkNaming.parse(key, raw), deprecated: op["deprecated"] == true, deprecation_note: nil,
              parameters: merge_parameters(document, item["parameters"] || [], op["parameters"] || [])
            )
          end
        end
      end
      unless missing.empty?
        raise Error, "These operations have no SDK naming (x-didit-sdk). Add an entry to openapi/overlay.json " \
                     "(or ask for x-didit-sdk upstream) with resource, method, auth and server; see " \
                     "docs/DESIGN.md section 4:\n  #{missing.join("\n  ")}"
      end
      stale = overlay.keys - seen
      unless stale.empty?
        raise Error, "openapi/overlay.json names operations that no longer exist upstream. Run " \
                     "codegen/spec_sync.rb, which records removed operations in openapi/deprecated-operations.json, " \
                     "or delete the entries:\n  #{stale.sort.join("\n  ")}"
      end
      @operations.concat(deprecated_operations(deprecated))
      check_unique
      check_scope
    end

    def server_operations
      operations.select(&:server?)
    end

    def self.key(api, http_method, path)
      "#{"account " if api == "account"}#{http_method.upcase} #{path}"
    end

    private

    def merge_parameters(document, shared, own)
      out = {}
      (shared + own).each do |raw|
        param = document.resolve(raw)
        out[[param["in"], param["name"]]] = param
      end
      out.values
    end

    # The methods openapi/deprecated-operations.json keeps for one more minor version:
    # operations removed upstream and the old names of renamed ones. Each entry holds
    # its own dereferenced copy of the operation.
    def deprecated_operations(deprecated)
      live = server_operations.to_h { |op| ["#{op.sdk.resource}.#{op.sdk.method}", op.key] }
      deprecated.sort.map do |name, entry|
        where = "openapi/deprecated-operations.json #{name}"
        sdk = SdkNaming.parse(where, entry["x-didit-sdk"])
        if "#{sdk.resource}.#{sdk.method}" != name
          raise Error,
                "#{where}: the entry name must equal its resource.method."
        end
        if live.key?(name)
          raise Error, "#{where}: #{live[name]} provides #{name} again, so it is no longer deprecated; " \
                       "delete this entry from openapi/deprecated-operations.json."
        end
        deprecated_operation(where, sdk, entry)
      end
    end

    def deprecated_operation(where, sdk, entry)
      key = entry["operation_key"].to_s
      api = key.start_with?("account ") ? "account" : "verification"
      http_method, path = key.delete_prefix("account ").split(" ", 2)
      unless HTTP_METHODS.include?(http_method.to_s.downcase) && path.to_s.start_with?("/")
        raise Error, "#{where}: operation_key #{key.inspect} is not \"METHOD /path\"."
      end

      op = entry["operation"]
      note = entry["note"] || if entry["replacement"]
                                "Renamed to #{entry["replacement"]}; this name is removed in version " \
                                  "#{entry["remove_in"]}."
                              else
                                "Removed from the API contract; this method is removed in version " \
                                  "#{entry["remove_in"]}."
                              end
      Operation.new(
        key: key, api: api, http_method: http_method.downcase, path: path, op: op,
        document: Document.new("#{api} (deprecated)", { "openapi" => "3.0.0", "paths" => {} }),
        sdk: sdk, deprecated: true, deprecation_note: note, parameters: op.fetch("parameters", [])
      )
    end

    def check_unique
      by_name = {}
      server_operations.each do |op|
        name = "#{op.sdk.resource}.#{op.sdk.method}"
        if by_name.key?(name)
          raise Error, "#{op.key} and #{by_name[name]} both map to #{name}; give one of them another method " \
                       "name in openapi/overlay.json."
        end
        by_name[name] = op.key
      end
      resources = server_operations.map { |op| op.sdk.resource }.uniq
      server_operations.each do |op|
        child = "#{op.sdk.resource}.#{op.sdk.method}"
        next unless resources.any? { |r| r == child || r.start_with?("#{child}.") }

        raise Error, "#{op.key}: method #{op.sdk.method.inspect} clashes with the nested resource #{child.inspect}."
      end
    end

    def check_scope
      operations.each do |op|
        scoped = op.sdk.scope == "application"
        next if scoped == op.path.start_with?(APPLICATION_PREFIX) || !op.server?

        raise Error, "#{op.key}: scope application needs a path under #{APPLICATION_PREFIX}." if scoped

        raise Error, "#{op.key}: a path under #{APPLICATION_PREFIX} needs scope \"application\"."
      end
    end
  end
end
