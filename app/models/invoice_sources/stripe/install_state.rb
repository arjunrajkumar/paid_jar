module InvoiceSources
  class Stripe
    class InstallState
      PURPOSE = "stripe_app_install"
      EXPIRES_IN = 15.minutes

      class << self
        def issue(account:, nonce:, app_id: Configuration.new.app_id)
          verifier.generate(
            {
              "account_id" => account.id,
              "app_id" => app_id,
              "nonce" => nonce
            },
            expires_in: EXPIRES_IN,
            purpose: PURPOSE
          )
        end

        def verify(token, nonce:, app_id: Configuration.new.app_id)
          payload = verifier.verify(token, purpose: PURPOSE)

          return unless secure_match?(payload.fetch("nonce"), nonce)
          return unless secure_match?(payload.fetch("app_id"), app_id)

          payload.fetch("account_id")
        rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError
          nil
        end

        private
          def verifier
            Rails.application.message_verifier(:stripe_app_install)
          end

          def secure_match?(actual, expected)
            actual.present? && expected.present? &&
              ActiveSupport::SecurityUtils.secure_compare(actual.to_s, expected.to_s)
          end
      end
    end
  end
end
