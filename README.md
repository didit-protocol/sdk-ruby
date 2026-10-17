# Didit Ruby SDK

The official [Didit](https://didit.me) Ruby library.
Identity verification (KYC), business verification (KYB), AML screening, biometrics, transaction monitoring, Travel Rule and customer authentication, from your backend.

> In development. Not released yet.

- Every Didit server API: sessions, standalone checks, KYB, users and businesses, workflows, webhooks, cases, transactions, wallet screening, Travel Rule and account management.
- Typed results with RBS signatures (checked with Steep), generated from the [OpenAPI contract](openapi/).
- Webhook verification and Didit Authentication (OpenID Connect) token verification built in.
- Standard library `net/http` with persistent connections, retries and timeouts. The only dependency is `jwt`, and only the Authentication module loads it.

## Install

```ruby
# Gemfile
gem "didit-sdk"
```

```sh
gem install didit-sdk
```

```ruby
require "didit"
```

Ruby 3.1 or newer (tested on 3.1, 3.2, 3.3, 3.4 and 4.0).

## Quickstart

Create a session, send the user to its URL, read the decision and verify the webhook Didit sends when it changes.

```ruby
require "didit"

didit = Didit::Client.new # reads DIDIT_API_KEY

session = didit.sessions.create(workflow_id: "your-workflow-id", vendor_data: "user-42")
redirect_to session.url

decision = didit.sessions.retrieve_decision(session.session_id)
decision.status # => "Approved", "Declined", "In Review", ...
decision.id_verifications&.first&.first_name

# In your webhook endpoint (Rails), with the raw body:
event = didit.webhooks.verify(request.raw_post, request.headers, ENV.fetch("DIDIT_WEBHOOK_SECRET"))
case event
in Didit::Webhooks::StatusUpdatedEvent(status: "Approved", session_id:) then approve(session_id)
in Didit::Webhooks::StatusUpdatedEvent then nil
in Didit::Webhooks::UnknownEvent then nil # a type this SDK version does not know yet
else nil
end
```

[`examples/quickstart.rb`](examples/quickstart.rb) runs the same steps. [`examples/`](examples/) also has standalone ID verification, AML screening, transaction screening, Travel Rule, Authentication, and webhook receivers for Rails, Sinatra and Rack.

## Configuration

```ruby
didit = Didit::Client.new(
  api_key: "...",              # default ENV["DIDIT_API_KEY"]
  organization_id: "...",      # default ENV["DIDIT_ORGANIZATION_ID"]; needed by application-scoped methods
  application_id: "...",       # default ENV["DIDIT_APPLICATION_ID"]; needed by application-scoped methods
  base_url: "https://verification.didit.me",
  account_base_url: "https://apx.didit.me/auth/v2",
  timeout: 60,                 # seconds per attempt
  max_retries: 2,
  default_headers: {},
  logger: nil,                 # any object with #debug; or DIDIT_LOG=debug for stderr
  http_client: nil             # ->(uri) { Net::HTTP.new(...) } for proxies or a CA bundle
)
```

- One client per process is the intended use. It is thread safe, keeps connections open per host, and a forked child never reuses its parent's connections.
- `with_options` returns a copy with some options changed that shares the connections: `didit.with_options(timeout: 5, max_retries: 0)`.
- Every method takes `request_options:` for one call: `{ timeout:, max_retries:, extra_headers:, extra_query:, extra_body: }`.
- Methods of the case, report and console resources are application scoped: the SDK fills `organization_id` and `application_id` from the client, and raises `Didit::ConfigurationError` before sending when either is missing.
- The API key is sent only to `base_url`. It never appears in logs, error messages or error bodies.

## Making calls

Resources follow the API: `didit.sessions`, `didit.sessions.imports`, `didit.users`, `didit.transactions.rules`, `didit.cases.notes`, and so on.
Ids in the URL are positional arguments; everything else is a keyword.

```ruby
didit.users.update("user-42", display_name: "Maria", metadata: { plan: "gold" })
didit.sessions.update_status(session_id, new_status: "Declined", comment: nil) # nil sends JSON null
```

A keyword you leave out is not sent. Unknown or missing keywords raise `ArgumentError`, like any Ruby method.
Nested objects are Hashes with the API's field names, as symbols or strings.

Results are typed objects:

```ruby
session.session_id         # typed reader
session[:session_id]       # any field, also ones this SDK version does not know yet
session.to_h               # the JSON object with symbol keys
session.created_at         # Time
```

`didit.with_raw_response` gives the HTTP response behind a result:

```ruby
raw = didit.with_raw_response.sessions.create(workflow_id: "...")
raw.status      # => 201
raw.request_id  # => "..."
session = raw.parse
```

## Errors

| Error | When |
|---|---|
| `Didit::DiditError` | base of everything below |
| `Didit::APIConnectionError` / `Didit::APITimeoutError` | no response |
| `Didit::APIStatusError` | any non-2xx, with `status`, `body`, `headers`, `request_id` |
| `BadRequestError` 400, `AuthenticationError` 401, `PermissionDeniedError` 403, `NotFoundError` 404, `ConflictError` 409, `UnprocessableEntityError` 422, `RateLimitError` 429, `InternalServerError` 5xx | subclasses of `APIStatusError` |
| `Didit::APIResponseValidationError` | a 2xx that is not the documented content, or a pagination link that loops or leaves the API |
| `Didit::WebhookVerificationError` | webhook verification failed, with a `reason` |
| `Didit::TokenVerificationError` | an Authentication token failed verification, with a `reason` |
| `Didit::ConfigurationError` | missing API key or ids, or an invalid argument, before anything is sent |

```ruby
begin
  didit.sessions.retrieve_decision(session_id)
rescue Didit::NotFoundError
  # ...
rescue Didit::APIStatusError => e
  logger.warn("Didit #{e.status}: #{e.message}") # the message ends with the request id
end
```

## Retries and timeouts

Failed requests are retried up to `max_retries` times (default 2) with exponential backoff from 0.5 s, full jitter, capped at 8 s, honouring `Retry-After` (capped at 60 s).
GET, HEAD, PUT and DELETE are retried on connection errors, timeouts, 408, 429 and 5xx.
POST and PATCH are retried only on 429 and when the connection failed before the request was sent, never after it may have reached the server.

## Pagination

```ruby
page = didit.sessions.list(limit: 50)
page.total_count          # the API's count across pages
page.each { |s| puts s.status } # this page
page.next_page            # the next Didit::Page, or nil

didit.sessions.list(limit: 50).auto_paging_each { |s| puts s.session_id } # every page, fetched as needed
```

## Files and binary responses

Upload arguments take a `Pathname`, an `IO` (`File`, `StringIO`, ...), a `String` with the file's bytes, or a `Didit::FilePart` to set the file name and content type:

```ruby
didit.id_verification.verify(front_image: Pathname("passport.jpg"))
didit.face_match.compare(user_image: File.open("selfie.jpg", "rb"), ref_image: Didit::FilePart.new(bytes, filename: "ref.png"))
```

Reports come back as bytes, or in chunks to a block:

```ruby
pdf = didit.sessions.generate_pdf(session_id)
File.open("report.pdf", "wb") { |f| didit.sessions.generate_pdf(session_id) { |chunk| f.write(chunk) } }
```

## Webhooks

```ruby
event = Didit::Webhooks.verify(raw_body, headers, secret)            # or didit.webhooks.verify(...)
event = Didit::Webhooks.verify(raw_body, headers, [new_secret, old_secret]) # during a rotation
```

- Pass the raw request body (`request.raw_post` in Rails, `request.body.read` in Sinatra and Rack). Headers can be a Hash in any case, a Rack env or Rails `request.headers`.
- A delivery is accepted when `X-Signature` matches the body, `X-Signature-V2` matches its canonical JSON, or a `-Previous` variant matches (secret rotation). Timestamps older or newer than `tolerance:` (300 s) are rejected.
- `verify_parsed(payload, headers, secret)` is for frameworks that only give you the parsed JSON; it can check `X-Signature-V2` only.
- The deprecated `X-Signature-Simple` counts only with `allow_simple: true`; then `event.body_authenticated?` is false and you should re-fetch the record from the API.
- Failures raise `Didit::WebhookVerificationError` with `reason`: `:missing_signature`, `:invalid_signature`, `:missing_timestamp`, `:timestamp_mismatch`, `:timestamp_out_of_tolerance` or `:invalid_payload`.
- Events are typed: `StatusUpdatedEvent`, `DataUpdatedEvent`, `UserStatusUpdatedEvent`, `UserDataUpdatedEvent`, `BusinessStatusUpdatedEvent`, `BusinessDataUpdatedEvent`, `ActivityCreatedEvent`, `TransactionCreatedEvent`, `TransactionStatusUpdatedEvent`, `TravelRuleStatusUpdatedEvent`, `WorkflowComplianceChangedEvent`, `KybRegistrySearchResolvedEvent`, and `UnknownEvent` for anything else. Session events carry the typed `decision`.
- `kyb.registry_search.resolved` callbacks arrive unsigned, so `verify` raises `:missing_signature` for them. `Didit::Webhooks.parse_event(JSON.parse(body))` reads one without verifying it; treat it as untrusted and re-fetch the data from the API.

See [`examples/webhooks/`](examples/webhooks/) for Rails, Sinatra and Rack receivers. In a Rails controller that inherits from `ActionController::Base`, skip CSRF protection for the webhook action.

## Transactions and Travel Rule

```ruby
txn = didit.transactions.create(
  transaction_id: "order-1001", transaction_category: "finance",
  transaction_details: { direction: "outbound", amount: 1500, currency: "EUR", action_type: "withdrawal" },
  subject: { entity_type: "individual", vendor_data: "user-42", full_name: "Maria Garcia" }
)
txn.status
didit.transactions.rules.list
didit.transactions.travel_rule.update_transfer(txn.txn_id, payment_txn_id: "0xabc...")
didit.wallet_screening.screen(wallet_address: "0x...", blockchain: "ethereum")
didit.travel_rule.list_vasps(search: "exchange")
```

Webhooks `transaction.created`, `transaction.status.updated` and `travel_rule.status.updated` arrive as typed events.

## Authentication

Didit Authentication gives your application an OpenID Connect issuer for your users. The `Didit::Authentication` module is for your backend: it verifies the tokens your frontend sends, exchanges codes, refreshes tokens, checks sessions and creates step-up verifications. It never uses the API key.

```ruby
auth = Didit::Authentication.new("https://acme.auth.didit.me", client_id: ENV["DIDIT_APPLICATION_ID"])
# or Didit::Authentication.from_publishable_key("pk_live_...")

claims = auth.verify_access_token(bearer_token)           # ES256, typ at+jwt, iss, exp/nbf/iat with 60 s leeway
claims.sub
claims.org&.role

pkce = Didit::Authentication.create_pkce                  # redirect with pkce.code_challenge, state and nonce
tokens = auth.exchange_code(params[:code], code_verifier: pkce.code_verifier, redirect_uri: callback_url)
id = auth.verify_id_token(tokens.id_token, nonce: session[:nonce])
tokens = auth.refresh(tokens.refresh_token)               # serialise refreshes per session: reusing one revokes it

auth.get_session(access_token)                            # instant revocation check
auth.revoke_session(access_token)
step_up = auth.create_step_up(access_token, action: "withdraw", amount: "250.00", currency: "EUR", return_to: url)
auth.retrieve_step_up(access_token, step_up.id).approved? # act only on status "approved"
```

Discovery and keys are fetched on first use and cached as the issuer's `Cache-Control` says; an unknown key id triggers at most one refetch per minute.
Rejected tokens raise `Didit::TokenVerificationError` with a `reason` such as `:unsupported_algorithm`, `:invalid_issuer`, `:invalid_audience`, `:expired` or `:unknown_key`.

## Account management

The `didit.account` methods use the account API (`https://apx.didit.me/auth/v2`) and a Bearer token instead of the API key:

```ruby
login = didit.account.login(email: "you@example.com", password: "...")
account = didit.with_options(account_token: login.access_token)
account.account.organizations.list
```

## Debug logging

`DIDIT_LOG=debug` prints one line per request to stderr: method, path, status, duration and request id. It never prints bodies, headers or query strings. Pass `logger:` to send the same lines to your logger.

## Language notes

Choices this SDK makes where [docs/DESIGN.md](docs/DESIGN.md) leaves the language idiom open:

- **Arguments.** Ids in the path are positional; request fields are keywords. An omitted keyword is left out of the request and `nil` sends JSON `null`. `Didit::OMIT` leaves a keyword out explicitly, which helps when building calls conditionally. Keywords that are Ruby keywords (`retry:`, `case:`) work as usual.
- **Names.** Methods and readers are snake_case. A field that would hide an `Object` method gets a trailing underscore (`method` is `method_`); camelCase fields read as snake_case (`firstName` is `first_name`). `model[:wireName]` always gives the raw value.
- **Types.** Responses are `Didit::Model` subclasses under `Didit::Types`, loaded on first use. Readers convert on access and never raise: a value with an unexpected shape comes back as it is. Date-times are `Time`, dates are `Date`, numbers are `Float`, and string decimals stay strings. Models support `to_h`, `to_json`, `==` and pattern matching (`in {status: "Approved"}`).
- **Open enums.** Known values are frozen string constants (`Didit::Types::SessionsRetrieveDecisionResponseStatus::APPROVED`, plus `VALUES`); values the SDK does not know are returned unchanged.
- **Signatures.** RBS signatures ship in `sig/` with the gem, so Steep users get typed calls and results. Readers of required fields are typed non-nil; if the API ever omits one, the reader returns nil.
- **Pages.** `Didit::Page` is `Enumerable` over the current page. Use `total_count` for the API's `count` (because `Enumerable#count` counts this page), `next_url`, `previous_url`, `next_page` and `auto_paging_each`. A `next` link to another origin, or one already followed, raises `APIResponseValidationError`. Lists that page with `next_offset` (case action receipts and duplicates) return plain results.
- **Errors.** Error names follow DESIGN. `APIResponseValidationError` (Python's name) covers 2xx responses that are not JSON and bad pagination links. Every check made before sending raises `ConfigurationError`, including invalid path ids (empty, `.` or `..`), uploads and request options. Verification `reason`s are Symbols.
- **Timeouts.** `timeout` applies to each attempt's connect, write and read separately, as net/http does; there is no overall deadline.
- **HTTP.** net/http with a small connection pool per origin. Redirects are never followed. Proxies come from the usual `http_proxy`/`https_proxy` variables, or from `http_client:`, a callable that returns a configured, not yet started `Net::HTTP` for a URI.
- **Uploads.** Files are read into memory before sending, so a retry can resend them. Content types come from a fixed table of file extensions, not the host's MIME database.
- **Deprecations.** Methods for operations removed from the API stay for one minor version and warn once through Ruby's `:deprecated` warning category (shown with `Warning[:deprecated] = true` or `ruby -W:deprecated`).
- **Webhooks.** The canonical JSON is serialised by the SDK itself, because Ruby prints floats differently from Python (`1.0e-05` instead of `1e-05`). `event.verified_by` names the header that matched. `verify` and `verify_parsed` take a `now:` keyword for tests.
- **Authentication.** The `jwt` gem checks the ES256 signature; the SDK checks everything else. `verify_id_token(token, nonce: nil)` requires a token without a nonce (the refresh case). A step-up's `method` field reads as `verification_method`. `clock:` (unix seconds) is for tests.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md): generated versus hand-written code, `bundle exec rake generate`, tests, the daily spec sync and releases.

## Versioning

[Semantic versioning](https://semver.org). The SDK stays on 0.x until its first public release; while on 0.x, a breaking change bumps the minor version. Releases are cut by release-please and the changelog is generated.

## Links

- API reference and guides: https://docs.didit.me
- Webhooks: https://docs.didit.me/integration/webhooks
- Design contract shared by every Didit server SDK: [docs/DESIGN.md](docs/DESIGN.md)
- Security: [SECURITY.md](SECURITY.md)

## License

MIT
