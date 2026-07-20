require "json"
require "stripe"

module InvoiceSources
  class Stripe
    class InstallSignature
      class Error < StandardError; end

      TIMESTAMP_TOLERANCE = 5.minutes

      def initialize(config: Configuration.new)
        @config = config
      end

      def verify!(state:, user_id:, account_id:, signature:)
        raise Error, "Stripe App signing secret is not configured." if config.signing_secrets.empty?
        raise Error, "Stripe installation signature is missing." if signature.blank?

        payload = JSON.generate(
          state: state.to_s,
          user_id: user_id.to_s,
          account_id: account_id.to_s
        )

        verify_with_any_secret!(payload, signature)
        true
      end

      private
        attr_reader :config

        def verify_with_any_secret!(payload, signature)
          raise Error, "Stripe installation signature timestamp is invalid." if timestamp_too_far_future?(signature)

          config.signing_secrets.each_with_index do |secret, index|
            return ::Stripe::Webhook::Signature.verify_header(
              payload,
              signature,
              secret.to_s,
              tolerance: TIMESTAMP_TOLERANCE.to_i
            )
          rescue ::Stripe::SignatureVerificationError
            raise Error, "Stripe installation signature could not be verified." if index == config.signing_secrets.length - 1
          end
        end

        def timestamp_too_far_future?(signature)
          timestamp = signature.to_s.split(",").filter_map do |part|
            key, value = part.split("=", 2)
            Integer(value) if key == "t"
          rescue ArgumentError
            nil
          end.first

          timestamp.present? && Time.zone.at(timestamp) > TIMESTAMP_TOLERANCE.from_now
        end
    end
  end
end
