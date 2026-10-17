# frozen_string_literal: true

require "json"
require "openssl"

# The namespace of the webhook specs: synthetic secrets and deliveries signed like the backend does.
module WebhookSpecs
  SECRET = "whsec_test_unit_secret_0001"
  PREVIOUS = "whsec_test_unit_secret_0000"
  NOW = 1_760_702_400
  VECTORS_FILE = File.expand_path("../../openapi/webhook-vectors.json", __dir__)
  PYTHON_CONSTANTS = { nil => "None", true => "True", false => "False" }.freeze

  module_function

  def vectors_document
    JSON.parse(File.read(VECTORS_FILE, encoding: "UTF-8"))
  end

  def sign(secret, message)
    OpenSSL::HMAC.hexdigest("SHA256", secret, message)
  end

  def payload(**extra)
    {
      "application_id" => "0b5e8d2c-1f4a-4c3b-9d6e-2a7f8c1b3e5d",
      "created_at" => NOW,
      "environment" => "sandbox",
      "event_id" => "7c9e6679-7425-40de-944b-e07fc1f90ae7",
      "session_id" => "11111111-2222-3333-4444-555555555555",
      "status" => "Approved",
      "timestamp" => NOW,
      "webhook_type" => "status.updated"
    }.merge(extra.transform_keys(&:to_s))
  end

  # The body and headers of a delivery: X-Signature over the body, X-Signature-V2 over its
  # canonical JSON, X-Signature-Simple over the envelope, and the -Previous variants with +previous+.
  def delivery(data = payload, secret: SECRET, previous: nil, body: JSON.generate(data))
    headers = signature_headers(body, data, secret)
    headers.merge!(signature_headers(body, data, previous).transform_keys { |name| "#{name}-Previous" }) if previous
    headers["X-Timestamp"] = data["timestamp"].to_s
    [body, headers]
  end

  def signature_headers(body, data, secret)
    canonical = Didit::Webhooks.canonical_json(JSON.parse(body))
    {
      "X-Signature" => sign(secret, body),
      "X-Signature-V2" => sign(secret, canonical),
      "X-Signature-Simple" => sign(secret, simple_message(data))
    }
  end

  # What the backend signs for X-Signature-Simple: str() of four fields, "" when missing.
  def simple_message(data)
    %w[timestamp session_id status webhook_type].map do |key|
      next "" unless data.key?(key)

      PYTHON_CONSTANTS.fetch(data[key]) { data[key].to_s }
    end.join(":")
  end

  # The reason of the WebhookVerificationError the block raises; nil when it raises none.
  def reason_of
    yield
    nil
  rescue Didit::WebhookVerificationError => e
    e.reason
  end

  def verification_error(reason)
    an_instance_of(Didit::WebhookVerificationError).and(having_attributes(reason: reason))
  end
end
