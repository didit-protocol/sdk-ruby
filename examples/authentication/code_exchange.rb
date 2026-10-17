# frozen_string_literal: true

# Sign a person in with Didit Authentication from a server-rendered app: PKCE,
# state and nonce, the code exchange, the ID token, a refresh, the live session,
# a step-up before a payout, and the sign-out.
#
#   export DIDIT_AUTH_ISSUER=https://<slug>.auth.didit.me   # or DIDIT_PUBLISHABLE_KEY=pk_test_...
#   export DIDIT_APPLICATION_ID=...                          # your application id (the OAuth client_id)
#   export DIDIT_REDIRECT_URI=https://app.example.com/callback  # one of the application's redirect URIs
#   ruby examples/authentication/code_exchange.rb
#
# The script prints the sign-in URL; open it, sign in, and paste the URL the
# browser was sent back to. A web app does the same in two routes: one that
# redirects to the sign-in page, and the redirect URI's handler.

require "didit"
require "openssl"
require "uri"

CLIENT_ID = ENV.fetch("DIDIT_APPLICATION_ID")
REDIRECT_URI = ENV.fetch("DIDIT_REDIRECT_URI")

publishable_key = ENV.fetch("DIDIT_PUBLISHABLE_KEY", nil)
AUTH = if publishable_key
         Didit::Authentication.from_publishable_key(publishable_key, client_id: CLIENT_ID)
       else
         Didit::Authentication.new(ENV.fetch("DIDIT_AUTH_ISSUER"), client_id: CLIENT_ID)
       end

# What your app keeps server-side for one signed-in person (in its session store).
# Refresh tokens are single use and presenting a used one revokes the session, so
# refreshes of one session must run one at a time: here under a Mutex; across
# processes use a database row lock or a distributed lock keyed by the session id.
SignedIn = Struct.new(:access_token, :refresh_token, :id_token, :lock, keyword_init: true) do
  def refresh!(auth)
    lock.synchronize do
      tokens = auth.refresh(refresh_token)
      self.access_token = tokens.access_token
      self.refresh_token = tokens.refresh_token
      self.id_token = tokens.id_token if tokens.id_token
      tokens
    end
  end
end

# 1. Before redirecting: keep the verifier, state and nonce server-side.
def sign_in_url(pkce, state, nonce)
  endpoint = AUTH.discovery.fetch("authorization_endpoint", "#{AUTH.issuer}/sign-in/")
  query = URI.encode_www_form(
    response_type: "code", client_id: CLIENT_ID, redirect_uri: REDIRECT_URI, scope: "openid email",
    state: state, nonce: nonce, code_challenge: pkce.code_challenge, code_challenge_method: pkce.code_challenge_method
  )
  "#{endpoint}?#{query}"
end

# 2. In the redirect URI's handler: check state, then exchange the code.
def handle_callback(callback_url, pkce, state, nonce)
  params = URI.decode_www_form(URI(callback_url).query.to_s).to_h
  abort "sign-in failed: #{params["error"]} #{params["error_description"]}" if params["error"]
  abort "state does not match: start again" unless OpenSSL.secure_compare(params.fetch("state", ""), state)

  tokens = AUTH.exchange_code(params.fetch("code"), code_verifier: pkce.code_verifier, redirect_uri: REDIRECT_URI)
  person = AUTH.verify_id_token(tokens.id_token, nonce: nonce)
  puts "signed in: #{person.sub} #{person.email} (#{person.amr&.join(", ")})"
  SignedIn.new(access_token: tokens.access_token, refresh_token: tokens.refresh_token, id_token: tokens.id_token,
               lock: Mutex.new)
end

# 3. Before a payout: ask whether the person must verify first.
def payout_approved?(signed_in, amount)
  step_up = AUTH.create_step_up(
    signed_in.access_token, action: "payout", amount: amount, currency: "EUR", return_to: REDIRECT_URI
  )
  # Fail closed: only an explicit "required": false lets the payout go ahead.
  return true if step_up.required == false

  puts "verify first: #{step_up.verification_url}"
  print "press Enter once you are back: "
  $stdin.gets
  # The ?status=approved on the return URL proves nothing: read the step-up.
  AUTH.retrieve_step_up(signed_in.access_token, step_up.id.to_s).approved?
end

if $PROGRAM_NAME == __FILE__
  begin
    pkce = Didit::Authentication.create_pkce
    state = Didit::Authentication.create_state
    nonce = Didit::Authentication.create_nonce
    puts "open: #{sign_in_url(pkce, state, nonce)}"
    print "paste the URL you were sent back to: "
    signed_in = handle_callback($stdin.gets.to_s.strip, pkce, state, nonce)

    claims = AUTH.verify_access_token(signed_in.access_token)
    puts "access token for #{claims.sub}, session #{claims.sid}, expires at #{Time.at(claims.exp.to_i)}"
    # The instant revocation check, for sensitive actions.
    session = AUTH.get_session(signed_in.access_token)
    puts "session #{session.sid} live until #{session.expires_at}"

    puts payout_approved?(signed_in, "900.00") ? "payout approved" : "payout not approved"

    refreshed = signed_in.refresh!(AUTH)
    # An ID token from a refresh carries no nonce.
    AUTH.verify_id_token(refreshed.id_token, nonce: nil) if refreshed.id_token
    puts "refreshed: #{AUTH.verify_access_token(signed_in.access_token).jti}"

    AUTH.revoke_session(signed_in.access_token)
    puts "signed out"
  rescue Didit::TokenVerificationError => e
    abort "token refused: #{e.reason}"
  rescue Didit::BadRequestError => e
    # invalid_grant: a used or expired code or refresh token. Sign in again; never retry.
    abort "the issuer refused the request: #{e.message}"
  end
end
