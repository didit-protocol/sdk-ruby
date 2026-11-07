# frozen_string_literal: true

# Didit webhook receiver as a plain Rack application, no framework.
#
#   gem install didit-sdk rack rackup puma
#   DIDIT_WEBHOOK_SECRET=... rackup examples/webhooks/config.ru
#
# Then point a Didit webhook destination at http://<your host>:9292/webhooks/didit.

require "didit"

# Verifies each delivery and answers 200, or 400/401 with the reason.
class DiditWebhookApp
  # Signature problems answer 401; a malformed, stale or replayed delivery answers 400.
  UNAUTHORIZED = %i[missing_signature invalid_signature].freeze
  TEXT = { "content-type" => "text/plain" }.freeze

  def call(env)
    return [405, TEXT, ["Method Not Allowed"]] unless env["REQUEST_METHOD"] == "POST"

    # The raw body, exactly as received, and the Rack env for the headers.
    body = env["rack.input"]&.read.to_s
    event = Didit::Webhooks.verify(body, env, ENV.fetch("DIDIT_WEBHOOK_SECRET"))
    handle(event, env["rack.errors"])
    [200, TEXT, ["ok"]]
  rescue Didit::WebhookVerificationError => e
    [UNAUTHORIZED.include?(e.reason) ? 401 : 400, TEXT, [e.reason.to_s]]
  end

  private

  def handle(event, log)
    case event
    in Didit::Webhooks::StatusUpdatedEvent(session_id:, status:)
      log.puts("Didit session #{session_id}: #{status}")
    in Didit::Webhooks::TravelRuleStatusUpdatedEvent(transaction_id:, travel_rule_status:)
      log.puts("Didit Travel Rule #{transaction_id}: #{travel_rule_status}")
    in Didit::Webhooks::UnknownEvent
      log.puts("Didit #{event.webhook_type} event, unknown to this SDK version")
    else
      log.puts("Didit #{event.webhook_type} event #{event.event_id}")
    end
  end
end

map "/webhooks/didit" do
  run DiditWebhookApp.new
end
