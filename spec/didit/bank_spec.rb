# frozen_string_literal: true

RSpec.describe "Bank data errors" do
  include ApiHelpers

  let(:client) { generated_test_client }

  it "exposes Retry-After and the code on a refresh limit 429" do
    body = {
      "code" => "refresh_limit_reached",
      "message" => "The bank's daily limit was reached.",
      "request_id" => "req-1",
      "field" => nil,
      "next_action" => "retry_later",
      "retry_after" => 120
    }
    stub_api(status: 429, headers: { "Retry-After" => "120", "X-Request-Id" => "req-1" }, body: JSON.generate(body))
    expect { client.bank.refresh_connection("connection-1") }.to raise_error(Didit::RateLimitError) do |error|
      expect(error.headers["retry-after"]).to eq("120")
      expect(error.body["code"]).to eq("refresh_limit_reached")
      expect(error.request_id).to eq("req-1")
    end
  end
end
