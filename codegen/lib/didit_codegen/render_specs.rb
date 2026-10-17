# frozen_string_literal: true

require "json"

module DiditCodegen
  # Writes one RSpec example per server operation (docs/DESIGN.md section 11) under spec/generated/.
  # The examples use the helpers in spec/support/api_helpers.rb.
  class SpecRenderer
    BASE_URLS = { "verification" => "https://verification.didit.me",
                  "account" => "https://apx.didit.me/auth/v2" }.freeze
    ORGANIZATION_ID = "org-7f3a"
    APPLICATION_ID = "app-91c2"
    SAFE_SEGMENT = /\A[A-Za-z0-9_~-]+\z/

    def initialize(types, resource_tree)
      @types = types
      @tree = resource_tree
    end

    # @return [Hash{String => String}] relative path => content
    def files
      @tree.children.each_value.to_h { |node| ["spec/generated/#{node.segment}_spec.rb", spec_file(node)] }
    end

    private

    def spec_file(node)
      examples = collect(node).map { |m| example(m) }
      <<~RUBY
        #{HEADER}
        # frozen_string_literal: true

        RSpec.describe Didit::Resources::#{node.class_name} do
          include ApiHelpers

          let(:client) { generated_test_client }

        #{examples.join("\n\n")}
        end
      RUBY
    end

    def collect(node)
      node.methods.sort_by(&:name) + node.children.values.flat_map { |child| collect(child) }
    end

    def example(meth)
      op = meth.op
      indent = "    "
      path_values = meth.path_args.to_h { |a| [a.wire, path_value(a)] }
      query = query_values(meth)
      body = body_values(meth)
      response_body = response_value(meth)
      lines = []
      lines << "  it #{"#{meth.resource}.#{meth.name} sends #{op.http_method.upcase} #{op.path}".inspect} do"
      lines.concat(stub_lines(meth, response_body, indent))
      lines.concat(call_lines(meth, path_values, query, body, indent))
      lines << "#{indent}request = expect_api_request("
      lines << "#{indent}  calls,"
      lines << "#{indent}  method: :#{op.http_method},"
      lines << "#{indent}  url: #{expected_url(meth, path_values).inspect},"
      lines << "#{indent}  query: #{Samples.literal(expected_query(meth, query), "#{indent}  ")},"
      lines << "#{indent}  auth: :#{op.sdk.auth},"
      lines << "#{indent}  accept: #{meth.response.accept.inspect}"
      lines << "#{indent})"
      lines.concat(body_assertions(meth, body, indent))
      if meth.idempotency
        lines << "#{indent}expect(request.headers[#{"Idempotency-Key".inspect}]).to eq(\"idem-key-1\")"
      end
      lines.concat(result_assertions(meth, indent))
      lines << "  end"
      lines.join("\n")
    end

    # Request values --------------------------------------------------------

    def path_value(arg)
      example = arg.example
      return example.to_s if arg.has_example && example.to_s.match?(SAFE_SEGMENT) && example.to_s.length <= 80

      schema = arg.schema.is_a?(Hash) ? arg.schema : {}
      return Samples::UUID if schema["format"] == "uuid"
      return "123" if schema["type"] == "integer"

      "#{arg.name.tr("_", "-")}-1"
    end

    def query_values(meth)
      meth.query_args.each_with_object({}) do |arg, out|
        next unless arg.required || arg.has_example

        value = scalar_example(arg) || Samples.synthesize(arg_document(meth), arg.schema, name: arg.wire)
        value = [value].flatten.compact.first(2) if arg.schema.is_a?(Hash) && arg.schema["type"] == "array"
        out[arg] = value
      end
    end

    def scalar_example(arg)
      return nil unless arg.has_example

      value = arg.example
      return value if [String, Integer, Float, TrueClass, FalseClass].any? { |k| value.is_a?(k) }
      return value if value.is_a?(Array) && !value.empty? && value.all? { |v| v.is_a?(String) || v.is_a?(Integer) }

      nil
    end

    def arg_document(meth)
      meth.op.document
    end

    def body_values(meth)
      return nil if meth.body_args.empty? && meth.whole_body.nil?

      document = meth.op.document
      raw = if meth.has_body_example && body_example_fits?(meth)
              Samples.scrub(meth.body_example)
            else
              meth.body_args.select(&:required).to_h do |a|
                [a.wire, Samples.synthesize(document, a.schema, name: a.wire)]
              end
            end
      raw = raw.reject { |k, _| meth.file_fields.include?(k) }
      meth.file_fields.each { |f| raw[f] = :file } if %i[multipart auto].include?(meth.encoding)
      raw
    end

    def body_example_fits?(meth)
      example = meth.body_example
      return false unless example.is_a?(Hash)

      wires = meth.body_args.map(&:wire)
      required = meth.body_args.select(&:required).map(&:wire)
      (example.keys - wires).empty? && (required - example.keys).empty?
    end

    def call_lines(meth, path_values, query, body, indent)
      args = meth.path_args.map { |a| path_values[a.wire].inspect }
      by_wire = meth.body_args.to_h { |a| [a.wire, a] }
      (body || {}).each do |wire, value|
        literal = value == :file ? file_literal(wire) : Samples.literal(value, "#{indent}  ", symbols: true)
        args << "#{by_wire.fetch(wire).name}: #{literal}"
      end
      query.each { |arg, value| args << "#{arg.name}: #{Samples.literal(value, "#{indent}  ")}" }
      args << "#{meth.idempotency.name}: \"idem-key-1\"" if meth.idempotency
      call = "client.#{meth.resource}.#{meth.name}"
      return ["#{indent}result = #{call}"] if args.empty?

      lines = args.each_with_index.map { |arg, i| "#{indent}  #{arg}#{',' unless i == args.size - 1}" }
      ["#{indent}result = #{call}(", *lines, "#{indent})"]
    end

    def file_literal(wire)
      "Didit::FilePart.new(#{"fake-#{wire}-bytes".inspect}, filename: #{"#{wire}.jpg".inspect}, " \
        "content_type: \"image/jpeg\")"
    end

    def expected_url(meth, path_values)
      path = meth.op.path.gsub(/\{([^}]+)\}/) do
        case Regexp.last_match(1)
        when "organization_id" then meth.op.sdk.scope ? ORGANIZATION_ID : path_values.fetch("organization_id")
        when "application_id" then meth.op.sdk.scope ? APPLICATION_ID : path_values.fetch("application_id")
        else path_values.fetch(Regexp.last_match(1))
        end
      end
      BASE_URLS.fetch(meth.op.api) + path
    end

    def expected_query(_meth, query)
      query.flat_map do |arg, value|
        Array(value).map { |v| [arg.wire, query_string(v)] }
      end
    end

    def query_string(value)
      case value
      when true, false then value.to_s
      else value.to_s
      end
    end

    def body_assertions(meth, body, indent)
      return ["#{indent}expect_no_body(request)"] if body.nil? && !meth.op.op["requestBody"]
      return ["#{indent}expect_json_body(request, {})"] if body.nil?

      if %i[multipart auto].include?(meth.encoding) && !meth.file_fields.empty?
        fields = body.reject { |_, v| v == :file }.transform_values { |v| multipart_text(v) }
        files = body.select { |_, v| v == :file }.to_h { |k, _| [k, ["#{k}.jpg", "image/jpeg", "fake-#{k}-bytes"]] }
        ["#{indent}expect_multipart_body(",
         "#{indent}  request,",
         "#{indent}  fields: #{Samples.literal(fields, "#{indent}  ")},",
         "#{indent}  files: #{Samples.literal(files, "#{indent}  ")}",
         "#{indent})"]
      elsif meth.encoding == :multipart
        fields = Samples.literal(body.transform_values { |v| multipart_text(v) }, indent)
        ["#{indent}expect_multipart_body(request, fields: #{fields}, files: {})"]
      else
        ["#{indent}expect_json_body(request, #{Samples.literal(body, indent)})"]
      end
    end

    def multipart_text(value)
      case value
      when Hash, Array then JSON.generate(value)
      else value.to_s
      end
    end

    # Responses -------------------------------------------------------------

    def response_value(meth)
      resp = meth.response
      return nil unless %i[model page].include?(resp.kind)

      document = meth.op.document
      type = resp.by_status ? resp.by_status.values.first : resp.type
      if resp.has_example && example_fits_type?(resp.example, type)
        Samples.scrub(resp.example)
      else
        Samples.synthesize(document, resp.schema, all: true)
      end
    end

    def example_fits_type?(example, type)
      case type.kind
      when :model then example.is_a?(Hash)
      when :array then example.is_a?(Array)
      when :union, :any, :object, :map then !example.nil?
      else !example.is_a?(Hash) && !example.is_a?(Array)
      end
    end

    def stub_lines(meth, response_body, indent)
      resp = meth.response
      status = resp.status
      case resp.kind
      when :none
        ["#{indent}calls = stub_api(status: #{status}, body: nil, content_type: nil)"]
      when :binary
        ["#{indent}calls = stub_api(status: #{status}, body: \"fake-binary-body\", content_type: #{resp.content_type.inspect})"]
      else
        json = JSON.pretty_generate(response_body)
        ["#{indent}calls = stub_api(status: #{status}, body: <<~'JSON')",
         *json.lines.map { |l| "#{indent}  #{l.rstrip}" },
         "#{indent}JSON"]
      end
    end

    def result_assertions(meth, indent)
      resp = meth.response
      case resp.kind
      when :none then ["#{indent}expect(result).to be_nil"]
      when :binary then ["#{indent}expect(result).to eq(\"fake-binary-body\")"]
      when :page
        ["#{indent}expect(result).to be_a(Didit::Page)",
         "#{indent}expect(result.to_h).to eq(JSON.parse(calls.body, symbolize_names: true))",
         *item_assertion(resp.item, indent),
         "#{indent}exercise_readers(result.results)"]
      else
        type = resp.by_status ? resp.by_status.fetch(resp.status) : resp.type
        lines = type_assertion(type, indent)
        lines << "#{indent}exercise_readers(result)"
        lines
      end
    end

    def item_assertion(item, indent)
      return [] unless item.kind == :model

      ["#{indent}expect(result.results).to all(be_a(Didit::Types::#{item.name}))"]
    end

    def type_assertion(type, indent)
      case type.kind
      when :model
        ["#{indent}expect(result).to be_a(Didit::Types::#{type.name})",
         "#{indent}expect(result.to_h).to eq(JSON.parse(calls.body, symbolize_names: true))"]
      when :array
        lines = ["#{indent}expect(result).to be_a(Array)"]
        lines << "#{indent}expect(result).to all(be_a(Didit::Types::#{type.inner.name}))" if type.inner.kind == :model
        lines
      else
        ["#{indent}expect(result).not_to be_nil"]
      end
    end
  end
end
