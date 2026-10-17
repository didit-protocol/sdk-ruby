# frozen_string_literal: true

require "json"

# What openapi/ promises, read directly from the documents (not through the generator).
module Contract
  ROOT = File.expand_path("..", __dir__)
  HTTP_METHODS = %w[get put post delete patch head options].freeze
  # Hand-written methods mounted on generated resources.
  EXTRA = %w[webhooks.verify webhooks.verify_parsed].freeze

  module_function

  def read(name)
    JSON.parse(File.read(File.join(ROOT, "openapi", name), encoding: "UTF-8"))
  end

  # Every operation: { name: "resource.method", naming:, path:, params: }.
  def operations
    @operations ||= spec_operations + deprecated_operations
  end

  def spec_operations
    overlay = read("overlay.json").fetch("operations")
    { "verification.json" => "", "account.json" => "account " }.flat_map do |file, prefix|
      read(file).fetch("paths").flat_map do |path, item|
        item.slice(*HTTP_METHODS).map do |http_method, op|
          naming = op["x-didit-sdk"] || overlay.fetch("#{prefix}#{http_method.upcase} #{path}")
          entry(naming, path, (item["parameters"] || []) + (op["parameters"] || []))
        end
      end
    end
  end

  def deprecated_operations
    file = File.join(ROOT, "openapi", "deprecated-operations.json")
    return [] unless File.exist?(file)

    read("deprecated-operations.json").fetch("methods", {}).values.map do |value|
      path = value.fetch("operation_key").split(" ").last
      entry(value.fetch("x-didit-sdk"), path, value.dig("operation", "parameters") || [])
    end
  end

  def entry(naming, path, params)
    { name: "#{naming["resource"]}.#{naming["method"]}", naming: naming, path: path, params: params }
  end

  def server
    operations.select { |o| o[:naming]["server"] }
  end

  def hidden
    operations.reject { |o| o[:naming]["server"] }
  end

  def client
    @client ||= Didit::Client.new(api_key: "k", organization_id: "o", application_id: "a")
  end

  # Every method the SDK exposes, found by walking the client's resources.
  def sdk_methods
    @sdk_methods ||= Didit::Resources::ClientMethods.public_instance_methods(false).flat_map do |name|
      walk(client.public_send(name), name.to_s)
    end - EXTRA
  end

  def walk(resource, prefix)
    names = resource.class.public_instance_methods(false) +
            resource.class.included_modules.select { |m| m.name&.start_with?("Didit::") }
                    .flat_map { |m| m.public_instance_methods(false) }
    names.uniq.sort.reject { |n| n == :inspect }.flat_map do |name|
      value = resource.method(name).arity.zero? ? resource.public_send(name) : nil
      value.is_a?(Didit::Resource) ? walk(value, "#{prefix}.#{name}") : ["#{prefix}.#{name}"]
    end
  end

  def method_for(dotted)
    *resources, name = dotted.split(".")
    resources.reduce(client) { |r, segment| r.public_send(segment) }.method(name)
  end

  # RBS method definitions of the generated resources, by "Class::Path#method".
  def signatures
    signatures = {}
    Dir[File.join(ROOT, "sig", "didit", "resources", "*.rbs")].each do |file|
      _, _, decls = RBS::Parser.parse_signature(File.read(file, encoding: "UTF-8"))
      decls.each { |decl| collect(decl, [decl.name.name.to_s], signatures) }
    end
    signatures
  end

  def collect(decl, path, out)
    decl.members.each do |member|
      case member
      when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
        collect(member, path + [member.name.name.to_s], out)
      when RBS::AST::Members::MethodDefinition
        out["#{path.drop(2).join("::")}##{member.name}"] = member
      end
    end
  end
end

# docs/DESIGN.md section 11: every server operation in openapi/ has exactly one SDK
# method, and nothing else exists.
RSpec.describe "API contract" do
  it "has one method per server operation" do
    expected = Contract.server.map { |o| o[:name] }
    expect(expected.uniq.size).to eq(expected.size)
    expect(Contract.sdk_methods - expected).to eq([]), "methods without an operation"
    expect(expected - Contract.sdk_methods).to eq([]), "operations without a method"
    expect(Contract.sdk_methods.size).to eq(Contract.server.size)
  end

  it "exposes no end-user or device token operation" do
    expect(Contract.sdk_methods & Contract.hidden.map { |o| o[:name] }).to eq([])
  end

  it "keeps the hand-written webhook methods on didit.webhooks" do
    expect(Contract.client.webhooks).to respond_to(:verify, :verify_parsed)
  end

  it "takes path parameters positionally, without the application scope ids" do
    Contract.server.each do |op|
      method = Contract.method_for(op[:name])
      placeholders = op[:path].scan(/\{([^}]+)\}/).flatten
      placeholders -= %w[organization_id application_id] if op[:naming]["scope"] == "application"
      expect(method.parameters.count { |kind, _| kind == :req }).to eq(placeholders.size), op[:name]
    end
  end

  it "takes request_options everywhere, idempotency_key where the API accepts one, and never the scope ids" do
    Contract.server.each do |op|
      keywords = Contract.method_for(op[:name]).parameters.filter_map do |kind, name|
        name if kind.to_s.start_with?("key")
      end
      idempotent = op[:params].any? { |p| p["in"] == "header" && p["name"].casecmp?("idempotency-key") }
      expect(keywords).to include(:request_options), op[:name]
      expect(keywords.include?(:idempotency_key)).to eq(idempotent), op[:name]
      expect(keywords & %i[organization_id application_id]).to eq([]), op[:name] if op[:naming]["scope"]
    end
  end

  it "matches the RBS signature of every generated method" do
    begin
      require "rbs"
    rescue LoadError
      skip "the rbs gem comes with Steep, on Ruby 3.3 or newer"
    end
    signatures = Contract.signatures
    Contract.server.each do |op|
      method = Contract.method_for(op[:name])
      key = "#{method.owner.name.delete_prefix("Didit::Resources::")}##{method.name}"
      type = signatures.fetch(key) { raise "no RBS signature for #{key}" }.overloads.first.method_type.type
      params = method.parameters.group_by(&:first).transform_values { |list| list.map(&:last).sort }
      expect(type.required_positionals.size).to eq(params.fetch(:req, []).size), key
      expect(type.required_keywords.keys.sort).to eq(params.fetch(:keyreq, [])), key
      expect(type.optional_keywords.keys.sort).to eq(params.fetch(:key, [])), key
    end
  end
end
