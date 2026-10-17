# frozen_string_literal: true

module Didit
  module Webhooks
    # A webhook event (docs/DESIGN.md section 9.4); {Didit::Webhooks.verify} returns the subclass
    # for its +webhook_type+.
    #
    # Every field Didit sent stays readable with {#[]} and {#to_h}, typed or not.
    class Event < Didit::Model
      # Unique id of the event; retries carry the same id, so use it to drop duplicates.
      field :event_id, "event_id", :string
      # Read by #webhook_type, which falls back to +event_type+.
      fields[:webhook_type] = ["webhook_type", :string].freeze
      # Unix seconds when the delivery was signed (X-Timestamp repeats it).
      field :timestamp, "timestamp", :integer
      # Unix seconds when the event happened, as sent.
      field :created_at, "created_at", :integer
      # The Didit application the event belongs to.
      field :application_id, "application_id", :string
      # +"live"+ or +"sandbox"+.
      field :environment, "environment", :string

      # Builds the event class that matches the payload's +webhook_type+ (or +event_type+).
      #
      # @api private
      def self.build(payload, verified_by = nil)
        data = payload.transform_keys(&:to_s) # a copy: the model freezes what it wraps
        type = data["webhook_type"]
        type = data["event_type"] unless type.is_a?(String)
        klass = type.is_a?(String) ? EVENT_CLASSES.fetch(type, UnknownEvent) : UnknownEvent
        klass.new(data, verified_by: verified_by)
      end

      # The signature header that verified the delivery (+"X-Signature"+, +"X-Signature-V2"+,
      # their +-Previous+ variants, +"X-Signature-Simple"+ or +"X-Signature-Simple-Previous"+);
      # nil for an event built with {Didit::Webhooks.parse_event}.
      #
      # @return [String, nil]
      attr_reader :verified_by

      # @param data [Hash] the parsed JSON body
      # @param verified_by [String, nil] the header that verified it
      def initialize(data = {}, verified_by: nil)
        super(data)
        @verified_by = verified_by
      end

      # The event type, for example +"status.updated"+. Callbacks that name it +event_type+
      # (+kyb.registry_search.resolved+) report that value.
      #
      # @return [String, nil]
      def webhook_type
        value = self["webhook_type"]
        return value if value.is_a?(String)

        fallback = self["event_type"]
        fallback.is_a?(String) ? fallback : value
      end

      # Whether a signature covered the whole body. False when only the deprecated
      # X-Signature-Simple matched (it signs timestamp, session_id, status and webhook_type,
      # nothing else): re-fetch the record from the API before trusting any other field.
      # Also false for an event built with {Didit::Webhooks.parse_event}.
      def body_authenticated?
        Verifier::FULL_BODY.include?(@verified_by)
      end
    end

    # Fields of the session events, +status.updated+ and +data.updated+.
    class SessionEvent < Event
      field :session_id, "session_id", :string
      # Set on business (KYB) sessions, where it equals session_id.
      field :business_session_id, "business_session_id", :string
      # +"user"+ or +"business"+.
      field :session_kind, "session_kind", :string
      field :status, "status", :string
      field :workflow_id, "workflow_id", :string
      field :workflow_version, "workflow_version", :any
      field :vendor_data, "vendor_data", :string
      field :metadata, "metadata", :any
      # The session decision, the shape +sessions.retrieve_decision+ returns.
      field :decision, "decision", "SessionsRetrieveDecisionResponse"
      # The steps the user must redo and why, when status is Resubmitted.
      field :resubmit_info, "resubmit_info", :any
    end

    # +status.updated+: a verification session changed status.
    class StatusUpdatedEvent < SessionEvent
      WEBHOOK_TYPE = "status.updated"
    end

    # +data.updated+: the data of a verification session changed.
    class DataUpdatedEvent < SessionEvent
      WEBHOOK_TYPE = "data.updated"
    end

    # Fields of the user events.
    class UserEvent < Event
      field :vendor_user_id, "vendor_user_id", :string
      field :vendor_data, "vendor_data", :string
      field :status, "status", :string
    end

    # +user.status.updated+: a user changed status.
    class UserStatusUpdatedEvent < UserEvent
      WEBHOOK_TYPE = "user.status.updated"
    end

    # +user.data.updated+: the data of a user changed.
    class UserDataUpdatedEvent < UserEvent
      WEBHOOK_TYPE = "user.data.updated"
    end

    # Fields of the business events.
    class BusinessEvent < Event
      field :vendor_business_id, "vendor_business_id", :string
      field :vendor_data, "vendor_data", :string
      field :status, "status", :string
    end

    # +business.status.updated+: a business changed status.
    class BusinessStatusUpdatedEvent < BusinessEvent
      WEBHOOK_TYPE = "business.status.updated"
    end

    # +business.data.updated+: the data of a business changed.
    class BusinessDataUpdatedEvent < BusinessEvent
      WEBHOOK_TYPE = "business.data.updated"
    end

    # Fields of the transaction monitoring events.
    class TransactionEvent < Event
      # Didit's transaction id.
      field :transaction_id, "transaction_id", :string
      # The transaction id you sent.
      field :txn_id, "txn_id", :string
      field :status, "status", :string
      field :score, "score", :float
      field :severity, "severity", :string
      # A decimal string, exactly as sent.
      field :amount, "amount", :any
      field :currency, "currency", :string
      field :direction, "direction", :string
      field :action_required, "action_required", :boolean
    end

    # +transaction.created+: a transaction was created.
    class TransactionCreatedEvent < TransactionEvent
      WEBHOOK_TYPE = "transaction.created"
    end

    # +transaction.status.updated+: a transaction changed status.
    class TransactionStatusUpdatedEvent < TransactionEvent
      WEBHOOK_TYPE = "transaction.status.updated"
    end

    # +travel_rule.status.updated+: the Travel Rule status of a transaction changed.
    class TravelRuleStatusUpdatedEvent < Event
      WEBHOOK_TYPE = "travel_rule.status.updated"

      field :transaction_id, "transaction_id", :string
      field :txn_id, "txn_id", :string
      field :travel_rule_status, "travel_rule_status", :string
      field :rail, "rail", :string
      field :direction, "direction", :string
    end

    # +activity.created+: an activity was recorded; read other fields with #[].
    class ActivityCreatedEvent < Event
      WEBHOOK_TYPE = "activity.created"
    end

    # +workflow.compliance_changed+: the compliance state of a workflow changed.
    class WorkflowComplianceChangedEvent < Event
      WEBHOOK_TYPE = "workflow.compliance_changed"

      field :workflow_id, "workflow_id", :string
    end

    # +kyb.registry_search.resolved+: an asynchronous KYB registry search (+kyb.search+ with
    # +webhook_url+) finished.
    #
    # Didit sends this callback unsigned (header +X-Didit-Unsigned-Callback: true+, the type in
    # +event_type+), so {Didit::Webhooks.verify} rejects it with +:missing_signature+. Read it with
    # {Didit::Webhooks.parse_event}, treat it as untrusted, and fetch the result from the API.
    class KybRegistrySearchResolvedEvent < Event
      WEBHOOK_TYPE = "kyb.registry_search.resolved"

      # The search request id +kyb.search+ returned.
      field :request_id, "request_id", :string
      field :vendor_data, "vendor_data", :string
      field :metadata, "metadata", :any
      # For example +"resolved"+.
      field :search_status, "search_status", :string
      field :search_resolved, "search_resolved", :boolean
      # The registry result with the candidate companies.
      field :kyb_registry, "kyb_registry", :any
    end

    # An event type this version of the SDK does not know; the whole payload stays readable
    # with #[] and #to_h.
    class UnknownEvent < Event
    end

    # The event class of each +webhook_type+; any other type is an {UnknownEvent}.
    EVENT_CLASSES = {
      StatusUpdatedEvent::WEBHOOK_TYPE => StatusUpdatedEvent,
      DataUpdatedEvent::WEBHOOK_TYPE => DataUpdatedEvent,
      UserStatusUpdatedEvent::WEBHOOK_TYPE => UserStatusUpdatedEvent,
      UserDataUpdatedEvent::WEBHOOK_TYPE => UserDataUpdatedEvent,
      BusinessStatusUpdatedEvent::WEBHOOK_TYPE => BusinessStatusUpdatedEvent,
      BusinessDataUpdatedEvent::WEBHOOK_TYPE => BusinessDataUpdatedEvent,
      ActivityCreatedEvent::WEBHOOK_TYPE => ActivityCreatedEvent,
      TransactionCreatedEvent::WEBHOOK_TYPE => TransactionCreatedEvent,
      TransactionStatusUpdatedEvent::WEBHOOK_TYPE => TransactionStatusUpdatedEvent,
      TravelRuleStatusUpdatedEvent::WEBHOOK_TYPE => TravelRuleStatusUpdatedEvent,
      WorkflowComplianceChangedEvent::WEBHOOK_TYPE => WorkflowComplianceChangedEvent,
      KybRegistrySearchResolvedEvent::WEBHOOK_TYPE => KybRegistrySearchResolvedEvent
    }.freeze
  end
end
