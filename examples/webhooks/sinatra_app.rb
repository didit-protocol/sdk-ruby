# frozen_string_literal: true

# Didit webhook receiver for Sinatra.
#
#   gem install didit-sdk sinatra
#   DIDIT_WEBHOOK_SECRET=... ruby examples/webhooks/sinatra_app.rb
#
# Then point a Didit webhook destination at http://<your host>:4567/webhooks/didit.

require "didit"
require "sinatra"

# Signature problems answer 401; a malformed, stale or replayed delivery answers 400.
UNAUTHORIZED = %i[missing_signature invalid_signature].freeze

post "/webhooks/didit" do
  # The raw body, exactly as received, and the Rack env for the headers.
  event = Didit::Webhooks.verify(request.body.read, request.env, ENV.fetch("DIDIT_WEBHOOK_SECRET"))

  case event
  when Didit::Webhooks::StatusUpdatedEvent
    logger.info("Didit session #{event.session_id}: #{event.status}")
  when Didit::Webhooks::TransactionCreatedEvent, Didit::Webhooks::TransactionStatusUpdatedEvent
    logger.info("Didit transaction #{event.transaction_id}: #{event.status} (score #{event.score})")
  when Didit::Webhooks::UnknownEvent
    logger.info("Didit #{event.webhook_type} event, unknown to this SDK version: #{event.to_h.keys.join(", ")}")
  else
    logger.info("Didit #{event.webhook_type} event #{event.event_id}")
  end
  status 200
rescue Didit::WebhookVerificationError => e
  halt UNAUTHORIZED.include?(e.reason) ? 401 : 400, e.reason.to_s
end
