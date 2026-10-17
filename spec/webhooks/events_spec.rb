# frozen_string_literal: true

require_relative "webhooks_helper"

module WebhookSpecs
  RSpec.describe "Didit::Webhooks events" do
    include WebhookSpecs

    def parse(**fields)
      Didit::Webhooks.parse_event(payload(**fields))
    end

    def types_available?
      Didit::Types.const_get(:SessionsRetrieveDecisionResponse, false)
      true
    rescue NameError, LoadError
      false
    end

    {
      "status.updated" => [Didit::Webhooks::StatusUpdatedEvent, { session_kind: "user", workflow_version: 2 }],
      "data.updated" => [Didit::Webhooks::DataUpdatedEvent, { business_session_id: "b-1", session_kind: "business" }],
      "user.status.updated" => [Didit::Webhooks::UserStatusUpdatedEvent, { vendor_user_id: "u-1", status: "ACTIVE" }],
      "user.data.updated" => [Didit::Webhooks::UserDataUpdatedEvent, { vendor_data: "customer-1" }],
      "business.status.updated" => [Didit::Webhooks::BusinessStatusUpdatedEvent, { vendor_business_id: "b-1" }],
      "business.data.updated" => [Didit::Webhooks::BusinessDataUpdatedEvent, { status: "FLAGGED" }],
      "activity.created" => [Didit::Webhooks::ActivityCreatedEvent, {}],
      "transaction.created" => [Didit::Webhooks::TransactionCreatedEvent, { amount: "10.00", txn_id: "t-1" }],
      "transaction.status.updated" => [Didit::Webhooks::TransactionStatusUpdatedEvent, { severity: "LOW" }],
      "travel_rule.status.updated" => [Didit::Webhooks::TravelRuleStatusUpdatedEvent, { rail: "TRP" }],
      "workflow.compliance_changed" => [Didit::Webhooks::WorkflowComplianceChangedEvent, { workflow_id: "w-1" }],
      "kyb.registry_search.resolved" => [Didit::Webhooks::KybRegistrySearchResolvedEvent, { request_id: "r-1" }]
    }.each do |type, (klass, fields)|
      it "reads #{type} as #{klass.name.split("::").last}" do
        event = parse(webhook_type: type, **fields)
        expect(event).to be_an_instance_of(klass)
        expect(event).to be_a(Didit::Webhooks::Event).and(be_a(Didit::Model))
        expect(event).to have_attributes(webhook_type: type, **fields)
        expect(klass::WEBHOOK_TYPE).to eq(type)
        expect(Didit::Webhooks::EVENT_CLASSES[type]).to eq(klass)
      end
    end

    it "has a class for every webhook type of DESIGN.md section 9.4" do
      expect(Didit::Webhooks::EVENT_CLASSES.keys).to contain_exactly(
        "status.updated", "data.updated", "user.status.updated", "user.data.updated", "business.status.updated",
        "business.data.updated", "activity.created", "transaction.created", "transaction.status.updated",
        "travel_rule.status.updated", "workflow.compliance_changed", "kyb.registry_search.resolved"
      )
    end

    it "reads the envelope on every event" do
      event = parse(webhook_type: "user.status.updated", environment: "live")
      expect(event).to have_attributes(
        event_id: "7c9e6679-7425-40de-944b-e07fc1f90ae7", timestamp: NOW, created_at: NOW,
        application_id: "0b5e8d2c-1f4a-4c3b-9d6e-2a7f8c1b3e5d", environment: "live"
      )
    end

    it "reads the session fields" do
      fields = { session_id: "s-1", business_session_id: nil, session_kind: "user", status: "Resubmitted",
                 workflow_id: "w-1", workflow_version: 4, vendor_data: "user-1", metadata: { "a" => [1] },
                 resubmit_info: { "steps" => ["ID_VERIFICATION"] } }
      expect(parse(**fields)).to have_attributes(**fields)
    end

    it "keeps the decision readable, and typed once the generated types are loaded" do
      decision = { "session_id" => "s-1", "status" => "Approved", "id_verifications" => [] }
      event = parse(decision: decision)
      expect(event[:decision]).to eq(decision)
      expect(event.to_h[:decision]).to eq({ session_id: "s-1", status: "Approved", id_verifications: [] })
      skip "Didit::Types is not generated yet" unless types_available?

      expect(event.decision).to be_a(Didit::Types::SessionsRetrieveDecisionResponse)
      expect(event.decision[:status]).to eq("Approved")
    end

    it "reads the transaction fields with the spec's types" do
      event = parse(webhook_type: "transaction.created", transaction_id: "t-1", score: 12, amount: "1500.00",
                    currency: "EUR", direction: "outbound", action_required: false)
      expect(event).to have_attributes(transaction_id: "t-1", score: 12.0, amount: "1500.00", currency: "EUR",
                                       direction: "outbound", action_required: false)
      expect(event.score).to be_a(Float)
    end

    it "reads the Travel Rule fields" do
      event = parse(webhook_type: "travel_rule.status.updated", transaction_id: "t-1", txn_id: "x-1",
                    travel_rule_status: "COMPLETED", rail: "TRP", direction: "inbound")
      expect(event).to have_attributes(transaction_id: "t-1", txn_id: "x-1", travel_rule_status: "COMPLETED",
                                       rail: "TRP", direction: "inbound")
    end

    describe "the KYB registry search callback" do
      let(:callback) do
        { "event_id" => "e-1", "event_type" => "kyb.registry_search.resolved", "request_id" => "r-1",
          "vendor_data" => "company-1", "metadata" => { "a" => 1 }, "search_status" => "resolved",
          "search_resolved" => true, "kyb_registry" => { "companies" => [{ "name" => "Tesco PLC" }] },
          "timestamp" => NOW, "created_at" => NOW }
      end

      it "is read from event_type with parse_event, unverified" do
        event = Didit::Webhooks.parse_event(callback)
        expect(event).to be_a(Didit::Webhooks::KybRegistrySearchResolvedEvent)
        expect(event).to have_attributes(webhook_type: "kyb.registry_search.resolved", request_id: "r-1",
                                         search_status: "resolved", search_resolved: true, vendor_data: "company-1",
                                         metadata: { "a" => 1 }, verified_by: nil, body_authenticated?: false)
        expect(event.kyb_registry["companies"].first["name"]).to eq("Tesco PLC")
      end

      it "is rejected by verify, because Didit sends it unsigned" do
        hdrs = { "X-Didit-Unsigned-Callback" => "true", "Content-Type" => "application/json" }
        expect { Didit::Webhooks.verify(JSON.generate(callback), hdrs, SECRET, now: NOW) }
          .to raise_error(verification_error(:missing_signature))
      end
    end

    describe "UnknownEvent" do
      ["auth.user.created", "transaction_rule_suggestions.created", "status.updated.v9", ""].each do |type|
        it "keeps a #{type.inspect} payload whole" do
          event = parse(webhook_type: type, suggestions: [{ "rule" => "r" }])
          expect(event).to be_an_instance_of(Didit::Webhooks::UnknownEvent)
          expect(event.webhook_type).to eq(type)
          expect(event[:suggestions]).to eq([{ "rule" => "r" }])
          expected = payload(webhook_type: type, suggestions: [{ "rule" => "r" }])
          expect(event.to_h).to eq(Didit::Model.symbolize(expected))
          expect(event.event_id).to eq("7c9e6679-7425-40de-944b-e07fc1f90ae7")
        end
      end

      it "is used when there is no type at all" do
        event = Didit::Webhooks.parse_event(payload.except("webhook_type"))
        expect(event).to be_an_instance_of(Didit::Webhooks::UnknownEvent)
        expect(event.webhook_type).to be_nil
      end
    end

    it "falls back to event_type when webhook_type is missing or not a String" do
      expect(parse(webhook_type: 5, event_type: "user.data.updated")).to be_a(Didit::Webhooks::UserDataUpdatedEvent)
      expect(parse(webhook_type: 5, event_type: "user.data.updated").webhook_type).to eq("user.data.updated")
      expect(parse(webhook_type: 5).webhook_type).to eq(5)
      expect(parse(webhook_type: "data.updated", event_type: "user.data.updated"))
        .to be_a(Didit::Webhooks::DataUpdatedEvent)
    end

    it "reads Symbol keys, keeps unknown fields and never raises on unexpected shapes" do
      data = Didit::Model.symbolize(payload(status: %w[not a string], extra: { "a" => 1 }))
      event = Didit::Webhooks.parse_event(data)
      expect(event).to be_a(Didit::Webhooks::StatusUpdatedEvent)
      expect(event.status).to eq(%w[not a string])
      expect(event[:extra]).to eq({ a: 1 })
      expect(event.key?(:extra)).to be(true)
    end

    it "supports pattern matching on the typed fields" do
      matched =
        case parse(status: "Approved")
        in Didit::Webhooks::StatusUpdatedEvent(status: "Approved", session_id:) then session_id
        in Didit::Webhooks::Event then nil
        end
      expect(matched).to eq("11111111-2222-3333-4444-555555555555")
      callback = { "event_type" => "kyb.registry_search.resolved", "search_resolved" => true }
      resolved = Didit::Webhooks.parse_event(callback) in { webhook_type: "kyb.registry_search.resolved", search_resolved: true }
      expect(resolved).to be(true)
    end

    it "parse_event needs a Hash and does not freeze it" do
      expect { Didit::Webhooks.parse_event("{}") }.to raise_error(ArgumentError, /Hash/)
      data = payload
      Didit::Webhooks.parse_event(data)
      expect(data).not_to be_frozen
    end

    it "reports which header verified a delivery" do
      raw, hdrs = delivery
      expect(Didit::Webhooks.verify(raw, hdrs, SECRET, now: NOW).verified_by).to eq("X-Signature")
      expect(parse.verified_by).to be_nil
      expect(parse.body_authenticated?).to be(false)
    end

    describe Didit::Webhooks::ClientMethods do
      let(:resource) { Class.new { include Didit::Webhooks::ClientMethods }.new }
      let(:signed) { delivery }

      it "verifies through the client resource" do
        raw, hdrs = signed
        expect(resource.verify(raw, hdrs, SECRET, now: NOW).verified_by).to eq("X-Signature")
        expect(resource.verify_parsed(JSON.parse(raw), hdrs, SECRET, now: NOW).verified_by).to eq("X-Signature-V2")
        expect(resource.verify(raw, hdrs.slice("X-Signature-Simple"), SECRET, now: NOW, allow_simple: true).verified_by)
          .to eq("X-Signature-Simple")
      end

      it "passes every option on" do
        allow(Didit::Webhooks).to receive_messages(verify: :event, verify_parsed: :parsed_event)
        expect(resource.verify("b", { "h" => "v" }, [SECRET], tolerance: 5, allow_simple: true, now: 1)).to eq(:event)
        expect(resource.verify_parsed({}, {}, SECRET, tolerance: 6, now: 2)).to eq(:parsed_event)
        expect(Didit::Webhooks).to have_received(:verify)
          .with("b", { "h" => "v" }, [SECRET], tolerance: 5, allow_simple: true, now: 1)
        expect(Didit::Webhooks).to have_received(:verify_parsed).with({}, {}, SECRET, tolerance: 6, now: 2)
      end

      it "is mixed into client.webhooks, which needs no API key" do
        webhooks = Didit::Client.new.webhooks
        raw, hdrs = signed
        expect(webhooks).to be_a(described_class)
        expect(webhooks.verify(raw, hdrs, SECRET, now: NOW).verified_by).to eq("X-Signature")
      end

      it "defaults like Didit::Webhooks.verify" do
        allow(Didit::Webhooks).to receive(:verify)
        resource.verify("b", {}, SECRET)
        expect(Didit::Webhooks).to have_received(:verify)
          .with("b", {}, SECRET, tolerance: 300, allow_simple: false, now: nil)
      end
    end
  end
end
