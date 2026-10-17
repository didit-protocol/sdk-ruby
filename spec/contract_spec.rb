# frozen_string_literal: true

require "json"

# docs/DESIGN.md section 11: every server operation in openapi/ has exactly one SDK
# method, and nothing else exists. This reads openapi/ directly (not the generator).
RSpec.describe "API contract" do
  root = File.expand_path("..", __dir__)
  read = ->(name) { JSON.parse(File.read(File.join(root, "openapi", name), encoding: "UTF-8")) }
  overlay = read.call("overlay.json").fetch("operations")
  deprecated_file = File.join(root, "openapi", "deprecated-operations.json")
  deprecated = File.exist?(deprecated_file) ? read.call("deprecated-operations.json").fetch("methods", {}) : {}

  operations = []
  { "verification.json" => "", "account.json" => "account " }.each do |file, prefix|
    read.call(file).fetch("paths").each do |path, item|
      item.each do |http_method, op|
        next unless %w[get put post delete patch head options].include?(http_method)

        naming = op["x-didit-sdk"] || overlay.fetch("#{prefix}#{http_method.upcase} #{path}")
        params = (item["parameters"] || []) + (op["parameters"] || [])
        operations << { naming: naming, path: path, params: params }
      end
    end
  end
  deprecated.each_value do |entry|
    key = entry.fetch("operation_key").delete_prefix("account ")
    operations << { naming: entry.fetch("x-didit-sdk"), path: key.split(" ", 2).last,
                    params: entry.dig("operation", "parameters") || [] }
  end
  server = operations.select { |o| o[:naming]["server"] }
  hidden = operations.reject { |o| o[:naming]["server"] }

  # Hand-written methods mounted on generated resources.
  extra = { "webhooks" => %w[verify verify_parsed] }

  client = Didit::Client.new(api_key: "k", organization_id: "o", application_id: "a")
  walk = lambda do |resource, name, out|
    methods = resource.class.public_instance_methods(false).map(&:to_s)
    methods += resource.class.included_modules.select { |m| m.name&.start_with?("Didit::") }
                       .flat_map { |m| m.public_instance_methods(false).map(&:to_s) }
    methods.uniq.sort.each do |method|
      next if method == "inspect"

      arity = resource.method(method).arity
      value = arity.zero? ? resource.public_send(method) : nil
      if value.is_a?(Didit::Resource)
        walk.call(value, "#{name}.#{method}", out)
      else
        out << "#{name}.#{method}"
      end
    end
  end
  sdk = []
  Didit::Resources::ClientMethods.public_instance_methods(false).each do |name|
    walk.call(client.public_send(name), name.to_s, sdk)
  end
  sdk.reject! { |full| extra.any? { |resource, names| names.any? { |n| full == "#{resource}.#{n}" } } }

  expected = server.map { |o| "#{o[:naming]["resource"]}.#{o[:naming]["method"]}" }

  it "has one method per server operation" do
    expect(expected.uniq.size).to eq(expected.size)
    expect(sdk.sort - expected.sort).to eq([]), "methods without an operation"
    expect(expected.sort - sdk.sort).to eq([]), "operations without a method"
    expect(sdk.size).to eq(server.size)
  end

  it "exposes no end-user or device token operation" do
    names = hidden.map { |o| "#{o[:naming]["resource"]}.#{o[:naming]["method"]}" }
    expect(sdk & names).to eq([])
  end

  it "keeps the hand-written webhook methods on didit.webhooks" do
    expect(client.webhooks).to respond_to(:verify, :verify_parsed)
  end

  def resolve(client, dotted)
    *resources, method = dotted.split(".")
    target = resources.reduce(client) { |r, name| r.public_send(name) }
    target.method(method)
  end

  it "takes path parameters positionally, without the application scope ids" do
    server.each do |op|
      naming = op[:naming]
      method = resolve(client, "#{naming["resource"]}.#{naming["method"]}")
      placeholders = op[:path].scan(/\{([^}]+)\}/).flatten
      placeholders -= %w[organization_id application_id] if naming["scope"] == "application"
      positional = method.parameters.select { |kind, _| kind == :req }.map(&:last)
      expect(positional.size).to eq(placeholders.size), "#{naming["resource"]}.#{naming["method"]}"
      keywords = method.parameters.select { |kind, _| %i[key keyreq].include?(kind) }.map(&:last)
      expect(keywords).to include(:request_options)
      expect(keywords).not_to include(:organization_id, :application_id) if naming["scope"] == "application"
      idempotent = op[:params].any? { |p| p["in"] == "header" && p["name"].casecmp?("idempotency-key") }
      expect(keywords.include?(:idempotency_key)).to eq(idempotent), "#{naming["resource"]}.#{naming["method"]}"
    end
  end

  it "matches the RBS signatures of every generated method" do
    begin
      require "rbs"
    rescue LoadError
      skip "the rbs gem is installed with Steep, on Ruby 3.3 or newer"
    end
    signatures = {}
    Dir[File.join(root, "sig", "didit", "resources", "*.rbs")].each do |file|
      _, _, decls = RBS::Parser.parse_signature(File.read(file, encoding: "UTF-8"))
      collect = lambda do |decl, prefix|
        decl.members.each do |member|
          case member
          when RBS::AST::Declarations::Class then collect.call(member, "#{prefix}::#{member.name.name}")
          when RBS::AST::Members::MethodDefinition then signatures["#{prefix}##{member.name}"] = member
          end
        end
      end
      decls.each do |mod|
        mod.members.each do |m|
          next unless m.respond_to?(:members)

          m.members.each do |c|
            collect.call(c, c.name.name.to_s)
          end
        end
      end
    end
    expected.each do |dotted|
      method = resolve(client, dotted)
      key = "#{method.owner.name.delete_prefix("Didit::Resources::")}##{method.name}"
      signature = signatures.fetch(key) { raise "no RBS signature for #{key}" }
      type = signature.overloads.first.method_type.type
      ruby = method.parameters
      expect(type.required_positionals.size).to eq(ruby.count { |k, _| k == :req }), key
      expect(type.required_keywords.keys.sort).to eq(ruby.select { |k, _| k == :keyreq }.map(&:last).sort), key
      expect(type.optional_keywords.keys.sort).to eq(ruby.select { |k, _| k == :key }.map(&:last).sort), key
    end
  end
end
