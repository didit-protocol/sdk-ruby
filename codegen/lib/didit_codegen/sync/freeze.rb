# frozen_string_literal: true

module DiditCodegen
  module Sync
    # A removed operation made self-contained for openapi/deprecated-operations.json:
    # every $ref inlined (from the old document), path-item parameters merged in, and
    # credential-like values replaced. Unlike the upstream copies, that file is not on the
    # secret scan allowlist (.gitleaks.toml).
    module Freeze
      # Operation keys that are not part of the contract the SDK method is built from.
      SKIP_KEYS = %w[x-didit-sdk x-codeSamples].freeze
      # Example values of fields with these names are replaced whatever they look like.
      CREDENTIAL_KEY = /(token|secret|password|passwd|passphrase|key|authorization|credential|cookie)s?\z/i
      # Replaced wherever they appear, descriptions included.
      JWT = /eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*/
      PRIVATE_KEY = /-----BEGIN [A-Z ]*PRIVATE KEY-----(?:.*?-----END [A-Z ]*PRIVATE KEY-----)?/m
      AUTH_VALUE = /\A(bearer|basic)\s+\S+/i

      module_function

      def operation(ref)
        op = ref.op.except(*SKIP_KEYS)
        params = (Array(ref.item["parameters"]) + Array(op["parameters"])).each_with_object({}) do |raw, out|
          param = ref.doc.expand(raw)
          out["#{param["in"]} #{param["name"]}"] = raw if param.is_a?(Hash)
        end
        op = op.merge("parameters" => params.values) unless params.empty?
        scrub(inline(ref.doc, op, []))
      end

      def inline(doc, node, stack)
        case node
        when Array then node.map { |v| inline(doc, v, stack) }
        when Hash
          ref = node["$ref"]
          return node.transform_values { |v| inline(doc, v, stack) } unless ref.is_a?(String)
          # A recursive schema stays open at the point where it repeats.
          return { "description" => "Recursive #{ref}, not expanded." } if stack.include?(ref)

          found = doc.target(ref)
          return { "description" => "Unresolvable #{ref}." } if found.nil?

          siblings = node.except("$ref")
          inline(doc, found.is_a?(Hash) ? found.merge(siblings) : found, stack + [ref])
        else node
        end
      end

      # Replaces credential-like values in example, examples and default, and JWTs and
      # private keys in every string.
      def scrub(node, name = nil)
        case node
        when Array then node.map { |v| scrub(v, name) }
        when Hash
          name = node["name"] if node["in"].is_a?(String) && node["name"].is_a?(String)
          node.to_h do |key, value|
            case key
            when "example", "default" then [key, scrub_value(value, name)]
            when "examples" then [key, scrub_examples(value, name)]
            when "properties"
              [key, value.is_a?(Hash) ? value.to_h { |prop, schema| [prop, scrub(schema, prop)] } : value]
            else [key, scrub(value, name)]
            end
          end
        when String then redact_patterns(node)
        else node
        end
      end

      def redact_patterns(text)
        text.gsub(JWT, "redacted-jwt").gsub(PRIVATE_KEY, "redacted-private-key")
      end

      def scrub_examples(examples, name)
        case examples
        when Hash
          examples.transform_values do |example|
            if example.is_a?(Hash) && example.key?("value")
              example.merge("value" => scrub_value(example["value"], name))
            else
              scrub_value(example, name)
            end
          end
        when Array then examples.map { |example| scrub_value(example, name) }
        else examples
        end
      end

      def scrub_value(value, key)
        case value
        when Hash then value.to_h { |k, v| [k, scrub_value(v, k)] }
        when Array then value.map { |v| scrub_value(v, key) }
        when String then credential(value, key) || redact_patterns(value)
        else value
        end
      end

      # The placeholder for a credential-like +value+, or nil when it looks harmless.
      def credential(value, key)
        return nil if value.empty?
        return "redacted-jwt" if value.match?(/\A#{JWT}\z/)
        return "redacted-authorization" if value.match?(AUTH_VALUE)
        return nil unless key.is_a?(String) && key.match?(CREDENTIAL_KEY)

        "redacted-#{key.downcase.gsub(/[^a-z0-9]+/, "-")}"
      end
    end
  end
end
