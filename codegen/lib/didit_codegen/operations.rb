# frozen_string_literal: true

module DiditCodegen
  BINARY_TYPES = %w[application/pdf text/csv image/ application/octet-stream application/zip].freeze

  # One argument of a generated method.
  Arg = Struct.new(:name, :wire, :location, :type, :required, :description, :schema, :example, :has_example,
                   keyword_init: true) do
    def keyword?
      Naming.keyword?(name)
    end

    # How the method body reads the argument (Ruby keywords cannot be local variables).
    def reader
      keyword? ? "binding.local_variable_get(:#{name})" : name
    end
  end

  # What a generated method returns.
  ResponseDef = Struct.new(:kind, :type, :by_status, :item, :accept, :status, :example, :has_example, :schema,
                           :content_type, :optional, keyword_init: true)

  # One generated SDK method.
  MethodDef = Struct.new(:op, :resource, :name, :path_args, :kwargs, :encoding, :file_fields, :idempotency,
                         :response, :body_example, :has_body_example, :whole_body, :summary, :description,
                         keyword_init: true) do
    def deprecated?
      op.deprecated
    end

    def body_args
      kwargs.select { |a| a.location == :body }
    end

    def query_args
      kwargs.select { |a| a.location == :query }
    end
  end

  # Turns each server operation into the description of one SDK method.
  class OperationBuilder
    RESERVED = %w[request_options].freeze

    def initialize(types)
      @types = types
    end

    def build(op)
      sdk = op.sdk
      rc = Naming.resource_classes(sdk.resource).join + Naming.pascal(sdk.method)
      group = sdk.resource.split(".").first
      used = RESERVED.dup
      path_args = build_path_args(op, used)
      kwargs = []
      encoding = :none
      file_fields = []
      body_example = nil
      has_body_example = false
      whole_body = nil
      if (request_body = op.op["requestBody"] && op.document.resolve(op.op["requestBody"]))
        schema, encoding, file_fields, media = merge_body(op, request_body.fetch("content", {}))
        has_body_example, body_example = example_of(media, op.document.resolve(schema))
        root = op.document.resolve(schema)
        type = @types.request(op.document, root, "#{rc}Params", group)
        if type.kind == :record && @types.registry.records[type.name]
          record = @types.registry.records[type.name]
          record.fields.each do |field|
            name = Naming.identifier(field.wire, used)
            used << name
            kwargs << Arg.new(name: name, wire: field.wire, location: :body, type: field.type,
                              required: field.required, description: field.description,
                              schema: property_schema(op.document, root, field.wire))
          end
        else
          name = Naming.identifier("body", used)
          used << name
          whole_body = Arg.new(name: name, wire: "", location: :body, type: type,
                               required: request_body["required"] == true,
                               description: text(request_body, "description"), schema: root)
        end
      end
      kwargs.concat(build_query_args(op, rc, group, used))
      idempotency = build_idempotency(op, used)
      MethodDef.new(
        op: op, resource: sdk.resource, name: sdk.method, path_args: path_args,
        kwargs: kwargs.partition(&:required).flatten, encoding: encoding, file_fields: file_fields,
        idempotency: idempotency, response: build_response(op, rc, group), body_example: body_example,
        has_body_example: has_body_example, whole_body: whole_body, summary: text(op.op, "summary"),
        description: text(op.op, "description")
      )
    end

    private

    def build_path_args(op, used)
      params = op.parameters.select { |p| p["in"] == "path" }.to_h { |p| [p["name"], p] }
      op.path.scan(/\{([^}]+)\}/).flatten.filter_map do |wire|
        next if op.sdk.scope == "application" && %w[organization_id application_id].include?(wire)

        param = params.fetch(wire, { "name" => wire, "schema" => { "type" => "string" } })
        schema = param["schema"] || { "type" => "string" }
        name = Naming.identifier(Naming.snake(wire), used)
        used << name
        has_example = param.key?("example") || (schema.is_a?(Hash) && schema.key?("example"))
        Arg.new(name: name, wire: wire, location: :path, type: TypeRef.scalar(:string), required: true,
                description: text(param, "description"), schema: schema,
                example: param.fetch("example") { schema.is_a?(Hash) ? schema["example"] : nil },
                has_example: has_example)
      end
    end

    def build_query_args(op, rc, group, used)
      op.parameters.select { |p| p["in"] == "query" }.map do |param|
        wire = param["name"]
        base = Naming.snake(wire)
        base = "#{base}_query" if used.include?(base)
        name = Naming.identifier(base, used)
        used << name
        schema = param["schema"] || {}
        type = @types.request(op.document, schema, "#{rc}Params#{Naming.pascal(wire)}", group)
        has_example = param.key?("example") || (schema.is_a?(Hash) && schema.key?("example"))
        Arg.new(name: name, wire: wire, location: :query, type: type, required: param["required"] == true,
                description: text(param, "description"), schema: schema,
                example: param.fetch("example") { schema.is_a?(Hash) ? schema["example"] : nil },
                has_example: has_example)
      end
    end

    def build_idempotency(op, used)
      param = op.parameters.find { |p| p["in"] == "header" && p["name"].casecmp?("idempotency-key") }
      return nil unless param

      name = Naming.identifier("idempotency_key", used)
      used << name
      Arg.new(name: name, wire: param["name"], location: :header, type: TypeRef.scalar(:string),
              required: false, description: text(param, "description"), schema: param["schema"] || {})
    end

    # The schema of the body arguments, the encoding, the file fields and the media object.
    def merge_body(op, content)
      json_media = content["application/json"]
      multipart_media = content["multipart/form-data"]
      if json_media.nil? && multipart_media.nil?
        json_media = content["application/x-www-form-urlencoded"]
        raise Error, "#{op.key}: unsupported request content types #{content.keys.sort.inspect}." if json_media.nil?
      end
      return [json_media.fetch("schema", {}), :json, [], json_media] if multipart_media.nil?

      if json_media.nil?
        schema = multipart_media.fetch("schema", {})
        return [schema, :multipart, binary_fields(op, schema).sort, multipart_media]
      end
      json_schema = op.document.resolve(json_media.fetch("schema", {}))
      multipart_schema = op.document.resolve(multipart_media.fetch("schema", {}))
      files = binary_fields(op, multipart_schema) - (json_schema["properties"] || {}).keys
      return [json_media.fetch("schema", {}), :json, [], json_media] if files.empty?

      props = (json_schema["properties"] || {}).dup
      (multipart_schema["properties"] || {}).each { |k, v| props[k] ||= v }
      # Either encoding works, so only a field both of them require is required.
      required = Array(json_schema["required"]) & Array(multipart_schema["required"])
      merged = json_schema.except("$ref").merge("properties" => props, "required" => required)
      [merged, :auto, files.sort, json_media]
    end

    def binary_fields(op, schema)
      schema = op.document.resolve(schema)
      (schema["properties"] || {}).filter_map do |name, prop|
        prop = op.document.resolve(prop)
        items = op.document.resolve(prop["items"] || {})
        name if prop["format"] == "binary" || (prop["type"] == "array" && items["format"] == "binary")
      end
    end

    def property_schema(document, root, wire)
      stack = [root]
      until stack.empty?
        cur = document.resolve(stack.pop)
        next unless cur.is_a?(Hash)
        return cur["properties"][wire] if cur["properties"]&.key?(wire)

        stack.concat(cur["allOf"] || [])
      end
      {}
    end

    def build_response(op, rc, group)
      successes = (op.op["responses"] || {}).select { |code, _| code.to_s.start_with?("2") }
                                            .map { |code, raw| [code.to_i, op.document.resolve(raw)] }
                                            .sort_by(&:first)
      json, binary, empty = classify_responses(op, successes)
      return json_response(op, rc, group, json, empty) unless json.empty?

      if binary
        code, content_type = binary
        return ResponseDef.new(kind: :binary, type: TypeRef.scalar(:binary), accept: "#{content_type}, application/json",
                               status: code, content_type: content_type)
      end
      ResponseDef.new(kind: :none, status: successes.first&.first || 204, accept: "application/json")
    end

    def classify_responses(op, successes)
      json = []
      binary = nil
      empty = false
      successes.each do |code, resp|
        content = resp["content"] || {}
        if (media = content["application/json"])
          json << [code, media.key?("schema") ? media : media.merge("schema" => {})]
        elsif (other = content.keys.find { |ct| BINARY_TYPES.any? { |b| ct.start_with?(b) } })
          binary = [code, other]
        elsif content.empty? && code != 204 && !%w[delete head].include?(op.http_method)
          # A body is promised but not described: return the JSON as is.
          json << [code, { "schema" => {} }]
        else
          empty = true
        end
      end
      [json, binary, empty]
    end

    def json_response(op, rc, group, json, empty)
      seen = []
      by_status = {}
      json.each_with_index do |(code, media), index|
        schema = media.fetch("schema", {})
        reuse = seen.find { |s, _| s == schema }
        if reuse
          by_status[code] = reuse.last
          next
        end
        hint = "#{rc}Response#{code unless index.zero?}"
        resolved = op.document.resolve(schema)
        type = if resolved.is_a?(Hash) && resolved["type"] == "array" && !schema.key?("$ref")
                 item = @types.response(op.document, resolved["items"] || {}, "#{hint}Item", group)
                 TypeRef.new(:array, inner: item, nullable: resolved["nullable"] == true)
               else
                 @types.response(op.document, schema, hint, group)
               end
        seen << [schema, type]
        by_status[code] = type
      end
      code, media = json.first
      has_example, example = example_of(media, op.document.resolve(media.fetch("schema", {})))
      distinct = by_status.values.uniq
      type = distinct.size == 1 ? distinct.first : TypeRef.new(:union, members: distinct)
      item = page_item(op, type)
      ResponseDef.new(kind: item ? :page : :model, type: type, by_status: distinct.size == 1 ? nil : by_status,
                      item: item, accept: "application/json", status: code, example: example,
                      has_example: has_example, schema: media.fetch("schema", {}), content_type: "application/json",
                      optional: empty)
    end

    def page_item(op, type)
      return nil unless op.http_method == "get" && type.kind == :model

      query = op.parameters.select { |p| p["in"] == "query" }.map { |p| p["name"] }
      return nil unless (%w[limit offset] - query).empty?

      fields = all_fields(type.name).to_h { |f| [f.wire, f] }
      return nil unless (%w[count next previous results] - fields.keys).empty?

      results = fields["results"].type
      results.kind == :array ? results.inner : nil
    end

    def all_fields(class_name)
      defn = @types.registry.classes.fetch(class_name)
      inherited = defn.superclass ? all_fields(defn.superclass) : []
      own = defn.fields.map(&:wire)
      inherited.reject { |f| own.include?(f.wire) } + defn.fields
    end

    def example_of(media, schema)
      return [false, nil] unless media.is_a?(Hash)
      return [true, media["example"]] if media.key?("example")

      examples = media["examples"]
      if examples.is_a?(Hash) && !examples.empty?
        first = examples.values.first
        return [true, first["value"]] if first.is_a?(Hash) && first.key?("value")
      end
      return [true, schema["example"]] if schema.is_a?(Hash) && schema.key?("example")

      [false, nil]
    end

    def text(node, key)
      value = node.is_a?(Hash) ? node[key] : nil
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    end
  end
end
