# frozen_string_literal: true

# Didit webhook receiver for Rails.
#
#   # Gemfile
#   gem "didit-sdk"
#
#   # config/routes.rb
#   post "/webhooks/didit", to: "didit_webhooks#create"
#
#   # app/controllers/didit_webhooks_controller.rb: this file
#
# Set DIDIT_WEBHOOK_SECRET to the destination's secret from the Didit console. During a secret
# rotation, pass both secrets: Didit::Webhooks.verify(body, headers, [new_secret, old_secret]).
class DiditWebhooksController < ActionController::API
  # Signature problems answer 401; a malformed, stale or replayed delivery answers 400.
  UNAUTHORIZED = %i[missing_signature invalid_signature].freeze

  def create
    # The raw body, exactly as received: never re-serialise params.
    event = Didit::Webhooks.verify(request.raw_post, request.headers, ENV.fetch("DIDIT_WEBHOOK_SECRET"))
    handle(event)
    head :ok
  rescue Didit::WebhookVerificationError => e
    render plain: e.reason.to_s, status: UNAUTHORIZED.include?(e.reason) ? :unauthorized : :bad_request
  end

  private

  # Didit retries a delivery until it gets a 2xx, with the same event_id: keep handlers idempotent.
  def handle(event)
    case event
    in Didit::Webhooks::StatusUpdatedEvent(status: "Approved", session_id:)
      Rails.logger.info("Didit session #{session_id} approved (vendor_data #{event.vendor_data})")
    in Didit::Webhooks::StatusUpdatedEvent | Didit::Webhooks::DataUpdatedEvent
      Rails.logger.info("Didit session #{event.session_id}: #{event.status}")
    in Didit::Webhooks::TransactionStatusUpdatedEvent(transaction_id:, status:)
      Rails.logger.info("Didit transaction #{transaction_id}: #{status}")
    in Didit::Webhooks::UserStatusUpdatedEvent | Didit::Webhooks::BusinessStatusUpdatedEvent
      Rails.logger.info("Didit entity status: #{event.status}")
    else
      # Other types, including ones newer than this SDK (UnknownEvent): read them with event[:field].
      Rails.logger.info("Didit #{event.webhook_type} event #{event.event_id}")
    end
  end
end
