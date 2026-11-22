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
      fields[:webhook_type] = ["webhook_type", :string]
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
      field :decision, "decision", "SessionDecision"
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

    # Fields of the Bank Link events; ids and statuses only, fetch the link from the API to read it.
    class BankLinkEvent < Event
      field :link_id, "link_id", :string
      # +"completed"+, +"cancelled"+, +"expired"+ or +"failed"+.
      field :status, "status", :string
      # The connection the link created or renewed, when there is one.
      field :connection_id, "connection_id", :string
      # The ownership result, when one was asked for.
      field :check_id, "check_id", :string
      # With +bank.link.failed+, for example +"consent_declined"+.
      field :error_code, "error_code", :string
    end

    # +bank.link.completed+: the person finished Bank Link.
    class BankLinkCompletedEvent < BankLinkEvent
      WEBHOOK_TYPE = "bank.link.completed"
    end

    # +bank.link.cancelled+: the person cancelled Bank Link.
    class BankLinkCancelledEvent < BankLinkEvent
      WEBHOOK_TYPE = "bank.link.cancelled"
    end

    # +bank.link.expired+: Bank Link expired before the person finished.
    class BankLinkExpiredEvent < BankLinkEvent
      WEBHOOK_TYPE = "bank.link.expired"
    end

    # +bank.link.failed+: Bank Link failed; +error_code+ says why.
    class BankLinkFailedEvent < BankLinkEvent
      WEBHOOK_TYPE = "bank.link.failed"
    end

    # Fields shared by the Bank connection events; ids and statuses only.
    class BankConnectionEvent < Event
      field :connection_id, "connection_id", :string
    end

    # +bank.connection.created+: the first sync of a connection finished.
    class BankConnectionCreatedEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.connection.created"

      # +"succeeded"+ or +"partial"+.
      field :initial_status, "initial_status", :string
    end

    # +bank.connection.updated+: a connection changed status; +revocation_status+ is +"pending"+
    # while a revocation waits for the bank.
    class BankConnectionUpdatedEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.connection.updated"

      field :status, "status", :string
      field :revocation_status, "revocation_status", :string
    end

    # +bank.connection.consent_expiring+: the consent ends in 14, 7 or 1 day.
    class BankConnectionConsentExpiringEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.connection.consent_expiring"

      field :days_left, "days_left", :integer
      field :consent_expires_at, "consent_expires_at", :datetime
      # Renew before this moment for no gap.
      field :renew_by, "renew_by", :datetime
    end

    # +bank.connection.renewal_required+: the consent ended or the bank asks the person to sign in.
    class BankConnectionRenewalRequiredEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.connection.renewal_required"

      field :status, "status", :string
      # +"consent_expired"+ or +"bank_requires_sign_in"+.
      field :reason, "reason", :string
      field :renew_by, "renew_by", :datetime
      # The last moment the same connection can be revived.
      field :renewable_until, "renewable_until", :datetime
    end

    # +bank.connection.renewed+: a renew link completed and the connection is readable again.
    class BankConnectionRenewedEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.connection.renewed"

      field :status, "status", :string
      field :consent_version, "consent_version", :integer
      # The renew link that completed, when there is one.
      field :link_id, "link_id", :string
      field :consent_expires_at, "consent_expires_at", :datetime
    end

    # +bank.connection.revoked+: access ended and the bank confirmed it.
    class BankConnectionRevokedEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.connection.revoked"

      field :status, "status", :string
      # +"end_user"+, +"bank"+, +"customer"+ or +"unknown"+.
      field :ended_by, "ended_by", :string
      field :status_reason, "status_reason", :string
      field :ended_at, "ended_at", :datetime
      # How long the stored data stays readable.
      field :retain_until, "retain_until", :datetime
    end

    # +bank.connection.deleted+: the stored data of a connection was deleted.
    class BankConnectionDeletedEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.connection.deleted"

      field :status, "status", :string
      field :erasure_status, "erasure_status", :string
      field :reason, "reason", :string
      field :erased_at, "erased_at", :datetime
    end

    # +bank.connection.history_complete+: the history backfill of a connection ended.
    class BankConnectionHistoryCompleteEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.connection.history_complete"

      field :status, "status", :string
    end

    # +bank.data.updated+: a sync stored new or changed bank data.
    class BankDataUpdatedEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.data.updated"

      field :sync_id, "sync_id", :string
      # +"initial"+, +"scheduled"+ or +"requested"+.
      field :trigger, "trigger", :string
      # One entry per changed account: +account_id+, +added+, +modified+ and +removed+.
      field :accounts, "accounts", :any
      field :balances_changed, "balances_changed", :boolean
    end

    # +bank.sync.completed+: a sync ended.
    class BankSyncCompletedEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.sync.completed"

      field :sync_id, "sync_id", :string
      field :trigger, "trigger", :string
      # +"succeeded"+, +"partial"+ or +"failed"+.
      field :outcome, "outcome", :string
      field :changed, "changed", :boolean
    end

    # +bank.sync.failed+: a sync failed; +failing_since+ says when the failures started.
    class BankSyncFailedEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.sync.failed"

      field :sync_id, "sync_id", :string
      field :error_code, "error_code", :string
      field :failing_since, "failing_since", :datetime
    end

    # +bank.sync.recovered+: a sync succeeded after failures.
    class BankSyncRecoveredEvent < BankConnectionEvent
      WEBHOOK_TYPE = "bank.sync.recovered"

      field :sync_id, "sync_id", :string
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
      KybRegistrySearchResolvedEvent::WEBHOOK_TYPE => KybRegistrySearchResolvedEvent,
      BankLinkCompletedEvent::WEBHOOK_TYPE => BankLinkCompletedEvent,
      BankLinkCancelledEvent::WEBHOOK_TYPE => BankLinkCancelledEvent,
      BankLinkExpiredEvent::WEBHOOK_TYPE => BankLinkExpiredEvent,
      BankLinkFailedEvent::WEBHOOK_TYPE => BankLinkFailedEvent,
      BankConnectionCreatedEvent::WEBHOOK_TYPE => BankConnectionCreatedEvent,
      BankConnectionUpdatedEvent::WEBHOOK_TYPE => BankConnectionUpdatedEvent,
      BankConnectionConsentExpiringEvent::WEBHOOK_TYPE => BankConnectionConsentExpiringEvent,
      BankConnectionRenewalRequiredEvent::WEBHOOK_TYPE => BankConnectionRenewalRequiredEvent,
      BankConnectionRenewedEvent::WEBHOOK_TYPE => BankConnectionRenewedEvent,
      BankConnectionRevokedEvent::WEBHOOK_TYPE => BankConnectionRevokedEvent,
      BankConnectionDeletedEvent::WEBHOOK_TYPE => BankConnectionDeletedEvent,
      BankConnectionHistoryCompleteEvent::WEBHOOK_TYPE => BankConnectionHistoryCompleteEvent,
      BankDataUpdatedEvent::WEBHOOK_TYPE => BankDataUpdatedEvent,
      BankSyncCompletedEvent::WEBHOOK_TYPE => BankSyncCompletedEvent,
      BankSyncFailedEvent::WEBHOOK_TYPE => BankSyncFailedEvent,
      BankSyncRecoveredEvent::WEBHOOK_TYPE => BankSyncRecoveredEvent
    }.freeze
  end
end
