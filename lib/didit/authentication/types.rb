# frozen_string_literal: true

module Didit
  class Authentication
    # +org+: the person's earliest organization membership, when customer
    # organizations are on.
    class OrganizationClaim < Model
      field :id, "id", :string
      # "admin", "member" or "billing"
      field :role, "role", :string
    end

    # +act+: the agent acting for the person. Only agent access tokens carry it.
    class ActorClaim < Model
      # The agent id.
      field :sub, "sub", :string
      # The agent's name.
      field :agent, "agent", :string
      # What the person allowed the agent to do; never act beyond these.
      field :scopes, "scopes", [:array, :string]
    end

    # +verified+: the highest approved verification level and the claims the
    # application selected. Empty when the person has not been verified.
    class VerifiedClaims < Model
      # "liveness", "liveness_face_match" or "full_id"
      field :level, "level", :string
      field :over_18, "over_18", :boolean
      field :over_21, "over_21", :boolean
      field :given_name, "given_name", :string
      field :family_name, "family_name", :string
      # YYYY-MM-DD
      field :birthdate, "birthdate", :string
      field :nationality, "nationality", :string
      field :country, "country", :string
      field :document_verified, "document_verified", :boolean
      field :liveness, "liveness", :boolean
    end

    # The claims access tokens and ID tokens share. Times are unix seconds.
    class TokenClaims < Model
      # The issuer.
      field :iss, "iss", :string
      # The identity id of the person.
      field :sub, "sub", :string
      # The application id: a String or an Array of them.
      field :aud, "aud", :any
      # The session id (the grant id on an agent token).
      field :sid, "sid", :string
      field :jti, "jti", :string
      field :iat, "iat", :integer
      field :exp, "exp", :integer
      field :nbf, "nbf", :integer
      # The person's reference across Didit products (verification sessions, monitoring).
      field :vendor_data, "vendor_data", :string
      # How the person signed in, for example ["passkey"]; empty on an agent token.
      field :amr, "amr", [:array, :string]
      field :org, "org", OrganizationClaim
      field :verified, "verified", VerifiedClaims
      # nil for a person; the agent on an agent access token.
      field :act, "act", ActorClaim
    end

    # The verified claims of an access token (header +typ: at+jwt+).
    class AccessTokenClaims < TokenClaims
      # The application id.
      field :client_id, "client_id", :string
    end

    # The verified claims of an ID token (header +typ: JWT+).
    class IdTokenClaims < TokenClaims
      field :auth_time, "auth_time", :integer
      field :nonce, "nonce", :string
      field :email, "email", :string
      field :email_verified, "email_verified", :boolean
      field :name, "name", :string
      field :phone_number, "phone_number", :string
    end

    # +POST token/+: new tokens. {#inspect} leaves the tokens out; never log them.
    class TokenResponse < Model
      SECRET_FIELDS = %w[access_token refresh_token id_token].freeze

      # A JWT access token that expires within five minutes.
      field :access_token, "access_token", :string
      # "Bearer"
      field :token_type, "token_type", :string
      # Seconds until the access token expires.
      field :expires_in, "expires_in", :integer
      # Opaque and single use: every refresh returns a new one.
      field :refresh_token, "refresh_token", :string
      field :id_token, "id_token", :string
      field :scope, "scope", :string
      field :session_id, "session_id", :string

      def inspect
        shown = raw_data.to_h { |key, value| [key, SECRET_FIELDS.include?(key) && value ? "[redacted]" : value] }
        "#<#{self.class.name} #{shown.inspect}>"
      end
      alias to_s inspect
    end

    # A custom organization role of {SessionOrganization}.
    class SessionCustomRole < Model
      field :key, "key", :string
      field :permissions, "permissions", [:array, :string]
    end

    # One organization of the person in {Session#organizations}.
    class SessionOrganization < Model
      field :organization_id, "organization_id", :string
      # Sent by the API as +organization__name+.
      field :organization_name, "organization__name", :string
      # "admin", "member" or "billing"
      field :role, "role", :string
      field :custom_role, "custom_role", SessionCustomRole
    end

    # +GET session/+: the live session behind an access token.
    class Session < Model
      # The identity id.
      field :sub, "sub", :string
      # The session id.
      field :sid, "sid", :string
      field :application_id, "application_id", :string
      field :vendor_data, "vendor_data", :string
      field :amr, "amr", [:array, :string]
      field :mfa_verified, "mfa_verified", :boolean
      field :email, "email", :string
      field :email_verified, "email_verified", :boolean
      field :phone, "phone", :string
      field :verified_identity, "verified_identity", [:map, :any]
      field :verified, "verified", VerifiedClaims
      field :expires_at, "expires_at", :datetime
      field :post_logout_redirect_uri, "post_logout_redirect_uri", :string
      field :organizations, "organizations", [:array, SessionOrganization]
    end

    # A step-up: +POST step-up/+ and +GET step-up/{id}/+.
    #
    # When +POST step-up/+ finds no rule that applies it answers only
    # +required: false+ and the action may go ahead. Otherwise send the person to
    # {#verification_url}, then read the step-up again with
    # {Authentication#retrieve_step_up} and act only when {#approved?} is true.
    class StepUp < Model
      # +POST step-up/+ only: whether the person must verify before the action.
      field :required, "required", :boolean
      field :id, "id", :string
      # "payout", "device", "bank" or "contact"
      field :rule, "rule", :string
      # The JSON property +method+ ("liveness", "selfie" or "full_id"); renamed
      # because +method+ is a core Ruby method.
      field :verification_method, "method", :string
      # "pending", "review", "approved", "declined", "expired" or "superseded"
      field :status, "status", :string
      # "liveness", "liveness_face_match" or "full_id"
      field :level, "level", :string
      field :amount, "amount", :string
      field :currency, "currency", :string
      field :created_at, "created_at", :datetime
      field :completed_at, "completed_at", :datetime
      field :expires_at, "expires_at", :datetime
      # +POST step-up/+ only: where to send the person to verify.
      field :verification_url, "verification_url", :string
      # +POST step-up/+ only: seconds the person has to verify.
      field :expires_in, "expires_in", :integer

      # True only for status "approved": the one status to act on.
      def approved?
        status == "approved"
      end
    end
  end
end
