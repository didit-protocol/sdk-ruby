# frozen_string_literal: true

require "json"
require "uri"

# docs/DESIGN.md section 11: every `server: true` operation of openapi/authentication.json
# has exactly one method of the hand-written Didit::Authentication (section 10), and nothing
# else exists. Each method sends its operation and reads the document's example response, so
# a spec sync that adds, removes or renames an Authentication operation fails here until the
# module follows.
module AuthenticationContract
  ROOT = File.expand_path("../..", __dir__)
  HTTP_METHODS = %w[get put post delete patch].freeze
  # x-didit-sdk method or variant => the module's method. The discovery document and key set
  # reads are named after what they return.
  METHODS = {
    "get_openid_configuration" => :discovery, "get_jwks" => :jwks, "exchange_code" => :exchange_code,
    "refresh" => :refresh, "get_session" => :get_session, "revoke_session" => :revoke_session,
    "create_step_up" => :create_step_up, "retrieve_step_up" => :retrieve_step_up
  }.freeze
  # Public methods that call no operation: offline token verification, the configuration
  # readers and connection handling; and the class methods (construction, PKCE, state, nonce).
  LOCAL = %i[verify_access_token verify_id_token issuer client_id timeout leeway close inspect to_s].freeze
  LOCAL_CLASS = %i[from_publishable_key create_pkce create_state create_nonce].freeze
  ACCESS_TOKEN = "synthetic-access-token-0001"
  # Each method's synthetic arguments and keywords, and the class of what it returns.
  CALLS = {
    discovery: [[], {}, Hash],
    jwks: [[], {}, Hash],
    exchange_code: [["synthetic-code"],
                    { code_verifier: "synthetic-code-verifier", redirect_uri: "https://app.example.com/callback" },
                    Didit::Authentication::TokenResponse],
    refresh: [["synthetic-refresh-token"], {}, Didit::Authentication::TokenResponse],
    get_session: [[ACCESS_TOKEN], {}, Didit::Authentication::Session],
    revoke_session: [[ACCESS_TOKEN], {}, NilClass],
    create_step_up: [[ACCESS_TOKEN], { action: "payout", amount: "900.00", currency: "USD" },
                     Didit::Authentication::StepUp],
    retrieve_step_up: [[ACCESS_TOKEN, "synthetic-step-up"], {}, Didit::Authentication::StepUp]
  }.freeze

  module_function

  def document
    @document ||= JSON.parse(File.read(File.join(ROOT, "openapi", "authentication.json"), encoding: "UTF-8"))
  end

  # [path, verb, operation] of every operation in the document.
  def each_operation(&)
    document.fetch("paths").flat_map do |path, item|
      item.slice(*HTTP_METHODS).map { |verb, op| [path, verb.upcase, op] }
    end.each(&)
  end

  # Every server operation and variant by its x-didit-sdk method: { verb:, path:, discriminator: }.
  def operations
    out = {}
    each_operation do |path, verb, op|
      naming = op.fetch("x-didit-sdk") { raise "#{verb} #{path} has no x-didit-sdk naming" }
      next unless naming["server"] == true
      raise "#{verb} #{path} is not an authentication operation" unless naming["resource"] == "authentication"

      Array(naming["variants"] || [{ "method" => naming.fetch("method") }]).each do |variant|
        name = variant.fetch("method")
        raise "#{name} names two operations" if out.key?(name)

        out[name] = { verb: verb, path: path, discriminator: variant["discriminator"] }
      end
    end
    out
  end

  # The issuer of the document's server URL, https://{issuer} with its default.
  def issuer
    "https://#{document.fetch("servers").first.dig("variables", "issuer", "default")}"
  end

  # A path of the document as a pattern; {placeholders} match one segment.
  def pattern(path)
    Regexp.new("\\A#{Regexp.escape(path).gsub(/\\\{[^}]+\\\}/, "[^/]+")}\\z")
  end

  # [status, JSON body or nil] of the first success response of +op+ and its example.
  def example(op)
    status, response = op.fetch("responses").find { |code, _| code.start_with?("2") }
    media = response.dig("content", "application/json")
    return [status.to_i, nil] if media.nil?

    examples = media["examples"]
    value = examples.is_a?(Hash) && !examples.empty? ? examples.values.first["value"] : media["example"]
    raise "#{status} has no example" if value.nil?

    [status.to_i, JSON.generate(value)]
  end

  # [verb, path pattern, status, body] answering every operation of the document.
  def routes
    out = []
    each_operation { |path, verb, op| out << [verb, pattern(path), *example(op)] }
    out
  end

  # The WebMock response for +request+: its operation's documented response.
  def respond(routes, request)
    verb = request.method.to_s.upcase
    _, _, status, body = routes.find { |route_verb, path, _, _| route_verb == verb && path.match?(request.uri.path) }
    raise "openapi/authentication.json has no operation #{verb} #{request.uri}" if status.nil?

    { status: status, body: body.to_s, headers: body ? { "Content-Type" => "application/json" } : {} }
  end
end

RSpec.describe "Authentication contract" do
  let(:requests) { [] }

  before do
    routes = AuthenticationContract.routes
    stub_request(:any, /\A#{Regexp.escape(AuthenticationContract.issuer)}/).to_return do |request|
      requests << request
      AuthenticationContract.respond(routes, request)
    end
  end

  it "has exactly one method for each server operation" do
    expect(AuthenticationContract.operations.keys.sort).to eq(AuthenticationContract::METHODS.keys.sort),
                                                           "the server operations of openapi/authentication.json " \
                                                           "differ from Didit::Authentication; update the module, " \
                                                           "METHODS and CALLS"
    expect(AuthenticationContract::CALLS.keys.sort).to eq(AuthenticationContract::METHODS.values.sort)
  end

  it "has no other public method" do
    expect(Didit::Authentication.public_instance_methods(false).sort)
      .to eq((AuthenticationContract::METHODS.values + AuthenticationContract::LOCAL).sort)
    expect(Didit::Authentication.singleton_methods(false).sort).to eq(AuthenticationContract::LOCAL_CLASS.sort)
  end

  it "sends each operation and reads its documented response" do
    AuthenticationContract.operations.each do |name, operation|
      method = AuthenticationContract::METHODS.fetch(name)
      arguments, keywords, result_class = AuthenticationContract::CALLS.fetch(method)
      requests.clear

      result = Didit::Authentication.new(AuthenticationContract.issuer).public_send(method, *arguments, **keywords)

      expect(result).to be_a(result_class), name
      request = requests.last
      expect(request.method.to_s.upcase).to eq(operation[:verb]), name
      expect(request.uri.path).to match(AuthenticationContract.pattern(operation[:path])), name
      next if operation[:discriminator].nil?

      expect(URI.decode_www_form(request.body.to_s).to_h["grant_type"]).to eq(operation[:discriminator]), name
    end
  end
end
