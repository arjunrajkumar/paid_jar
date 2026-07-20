require "digest"

module InvoiceSources
  class Stripe
    class InstallationClaim < ApplicationRecord
      self.table_name = "stripe_installation_claims"

      EXPIRES_IN = 15.minutes
      TOKEN_BYTES = 32

      class Error < StandardError; end

      belongs_to :account, optional: true

      validates :token_digest, :request_digest, :stripe_account_id, :stripe_user_id, :expires_at, presence: true
      validates :token_digest, :request_digest, uniqueness: true
      validates :livemode, inclusion: { in: [ true, false ] }

      class << self
        def issue!(stripe_account_id:, stripe_user_id:, livemode:, request_digest:)
          token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
          claim = create!(
            token_digest: digest(token),
            request_digest:,
            stripe_account_id:,
            stripe_user_id:,
            livemode:,
            expires_at: EXPIRES_IN.from_now
          )

          [ claim, token ]
        rescue ActiveRecord::RecordNotUnique
          raise Error, "This Stripe App request was already used."
        rescue ActiveRecord::RecordInvalid => error
          raise unless error.record.is_a?(self) && error.record.errors.of_kind?(:request_digest, :taken)

          raise Error, "This Stripe App request was already used."
        end

        def active_for_token(token)
          find_by(token_digest: digest(token))&.then { |claim| claim if claim.active? }
        end

        private
          def digest(token)
            Digest::SHA256.hexdigest(token.to_s)
          end
      end

      def active?
        consumed_at.nil? && expires_at.future?
      end

      def consume!(account:)
        with_lock do
          raise Error, "This Stripe connection link has expired or was already used." unless active?
          unless Configuration.new.secret_key_configured?(livemode:)
            raise Error, "Stripe API credentials are not configured for this environment."
          end

          source = account.with_lock do
            InvoiceSources::Stripe.new(
              account.invoice_sources.find_or_initialize_by(provider: :stripe)
            ).connect_from_install!(
              stripe_account_id:,
              stripe_user_id:,
              livemode:
            )
          end

          update!(account:, consumed_at: Time.current)
          source
        end
      end
    end
  end
end
