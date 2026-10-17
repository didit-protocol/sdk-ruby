# frozen_string_literal: true

# Quickstart: create a verification session, read its decision and verify a webhook.
#
#   export DIDIT_API_KEY=...             # Didit console > API keys
#   export DIDIT_WORKFLOW_ID=...         # the workflow the session runs
#   ruby -Ilib examples/quickstart.rb
#
# DIDIT_BASE_URL points the client somewhere else (for example a local mock server).

require "didit"
require "json"
require "openssl"

didit = Didit::Client.new(base_url: ENV.fetch("DIDIT_BASE_URL", Didit::Client::DEFAULT_BASE_URL))

# 1. Create a session and send the user to its URL.
session = didit.sessions.create(workflow_id: ENV.fetch("DIDIT_WORKFLOW_ID"), vendor_data: "user-42")
puts "Session #{session.session_id}: send the user to #{session.url}"

# 2. Read the decision (after the user finished, or when the webhook arrives).
decision = didit.sessions.retrieve_decision(session.session_id)
puts "Decision: #{decision.status}"
case decision.status
when Didit::Types::SessionsRetrieveDecisionResponseStatus::APPROVED then puts "Approved"
when Didit::Types::SessionsRetrieveDecisionResponseStatus::DECLINED then puts "Declined"
else puts "Not final yet (#{decision.status}); unknown statuses never raise"
end

# 3. Verify a webhook. A real receiver gets the raw body and headers from its framework
#    (see examples/webhooks/); here a delivery is signed locally to show the call.
secret = ENV.fetch("DIDIT_WEBHOOK_SECRET", "whsec_test_quickstart_example")
timestamp = Time.now.to_i
body = JSON.generate(
  "event_id" => "evt-1", "webhook_type" => "status.updated", "session_id" => session.session_id,
  "status" => "Approved", "timestamp" => timestamp
)
headers = {
  "X-Signature" => OpenSSL::HMAC.hexdigest("SHA256", secret, body),
  "X-Timestamp" => timestamp.to_s
}
event = didit.webhooks.verify(body, headers, secret)
puts "Webhook #{event.webhook_type} for #{event.session_id} verified by #{event.verified_by} " \
     "(#{event.class.name.split('::').last})"

begin
  didit.webhooks.verify(body.sub("Approved", "Declined"), headers, secret)
rescue Didit::WebhookVerificationError => e
  puts "Tampered webhook rejected: #{e.reason}"
end
