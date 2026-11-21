# frozen_string_literal: true

RSpec.describe Didit::Resources::Messages do
  include ApiHelpers

  it "sends free text as a message field" do
    calls = stub_api(status: 201, body: "{}")
    generated_test_client.messages.send_message(to: "+12025550123", body: "hello")
    expect_json_body(calls.requests.fetch(0), { "to" => "+12025550123", "body" => "hello" })
  end

  it "sends a template and its variables without a text body" do
    calls = stub_api(status: 201, body: "{}")
    generated_test_client.messages.send_message(to: "+12025550123", template_id: "template-1", variables: { order: "42" })
    expect_json_body(calls.requests.fetch(0), { "to" => "+12025550123", "template_id" => "template-1",
                                               "variables" => { "order" => "42" } })
  end
end
