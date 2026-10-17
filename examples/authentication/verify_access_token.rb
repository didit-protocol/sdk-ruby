# frozen_string_literal: true

# Verify the Didit Authentication access token of every API request in a plain
# Rack middleware, and answer 401 with the reason when it is not valid.
#
#   export DIDIT_AUTH_ISSUER=https://<slug>.auth.didit.me   # or DIDIT_PUBLISHABLE_KEY=pk_live_...
#   export DIDIT_APPLICATION_ID=...                          # your application id (the OAuth client_id)
#   ruby examples/authentication/verify_access_token.rb <access token>
#
# In a Rack app (config.ru):          use RequireDiditUser, didit_authentication
# In Rails (config/application.rb):   config.middleware.use RequireDiditUser, didit_authentication

require "didit"
require "json"

# One instance per process: it caches the issuer's discovery document and keys.
def didit_authentication
  client_id = ENV.fetch("DIDIT_APPLICATION_ID", nil)
  publishable_key = ENV.fetch("DIDIT_PUBLISHABLE_KEY", nil)
  if publishable_key
    Didit::Authentication.from_publishable_key(publishable_key, client_id: client_id)
  else
    Didit::Authentication.new(ENV.fetch("DIDIT_AUTH_ISSUER"), client_id: client_id)
  end
end

# Rack middleware: puts the verified claims in env["didit.claims"], or answers
# 401 (invalid token) or 503 (the issuer's keys could not be fetched).
class RequireDiditUser
  JSON_TYPE = { "content-type" => "application/json" }.freeze

  def initialize(app, auth)
    @app = app
    @auth = auth
  end

  def call(env)
    scheme, token = env["HTTP_AUTHORIZATION"].to_s.split(" ", 2)
    return unauthorized("missing_token") unless scheme&.casecmp?("bearer") && token && !token.empty?

    # The offline check: signature, issuer, audience (the client id) and expiry.
    # Before a sensitive action also call @auth.get_session(token), which sees a
    # session revoked a moment ago.
    env["didit.claims"] = @auth.verify_access_token(token)
  rescue Didit::TokenVerificationError => e
    unauthorized(e.reason.to_s)
  rescue Didit::APIConnectionError, Didit::APIStatusError, Didit::APIResponseValidationError
    # Not the caller's fault: the issuer could not be reached. Try again later.
    [503, JSON_TYPE.merge("retry-after" => "60"), [JSON.generate({ error: "temporarily_unavailable" })]]
  else
    # Errors from the application itself are not caught above.
    @app.call(env)
  end

  private

  def unauthorized(reason)
    headers = JSON_TYPE.merge("www-authenticate" => %(Bearer error="invalid_token", error_description="#{reason}"))
    [401, headers, [JSON.generate({ error: "invalid_token", reason: reason })]]
  end
end

# The protected application: it only runs for a verified person or agent.
HELLO = lambda do |env|
  claims = env.fetch("didit.claims")
  body = { sub: claims.sub, session: claims.sid, vendor_data: claims.vendor_data, agent: claims.act&.sub }
  [200, RequireDiditUser::JSON_TYPE, [JSON.generate(body)]]
end

if $PROGRAM_NAME == __FILE__
  token = ARGV.fetch(0) { abort "usage: ruby #{$PROGRAM_NAME} <access token>" }
  app = RequireDiditUser.new(HELLO, didit_authentication)
  status, _headers, body = app.call({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })
  puts "#{status} #{body.join}"
end
