require "digest"
require "json"
require "stripe"

module InvoiceSources
  class Stripe
    class AppRequest
      class Error < StandardError; end

      TIMESTAMP_TOLERANCE = 5.minutes
      ADMINISTRATOR_ROLE_IDS = %w[admin super_admin].freeze
      ADMINISTRATOR_ROLE_NAMES = [ "Administrator", "Super Administrator" ].freeze
      Context = Data.define(:stripe_account_id, :stripe_user_id, :livemode, :request_digest)
      EXPECTED_KEYS = %w[account_id livemode stripe_roles user_id].freeze

      def initialize(config: Configuration.new)
        @config = config
      end

      def verify!(payload:, signature:)
        raise Error, "Stripe App signing secret is not configured." if config.signing_secrets.empty?
        raise Error, "Stripe App signature is missing." if signature.blank?

        attributes = JSON.parse(payload)
        validate_attributes!(attributes)
        verify_with_any_secret!(payload, signature)

        Context.new(
          stripe_account_id: attributes.fetch("account_id"),
          stripe_user_id: attributes.fetch("user_id"),
          livemode: attributes.fetch("livemode"),
          request_digest: Digest::SHA256.hexdigest("#{payload}\0#{signature}")
        )
      rescue JSON::ParserError
        raise Error, "Stripe App sent invalid JSON."
      end

      private
        attr_reader :config

        def validate_attributes!(attributes)
          unless attributes.is_a?(Hash) && attributes.keys.sort == EXPECTED_KEYS
            raise Error, "Stripe App request has invalid fields."
          end

          unless attributes.fetch("account_id").to_s.start_with?("acct_") &&
              attributes.fetch("user_id").to_s.start_with?("usr_") &&
              [ true, false ].include?(attributes.fetch("livemode"))
            raise Error, "Stripe App request has invalid values."
          end

          validate_roles!(attributes.fetch("stripe_roles"))
        end

        def validate_roles!(roles)
          valid_roles = roles.is_a?(Array) && roles.present? && roles.all? do |role|
            role.is_a?(Hash) &&
              role["type"] == "builtIn" &&
              role["name"].is_a?(String) &&
              (!role.key?("id") || role["id"].is_a?(String))
          end
          raise Error, "Stripe App request has invalid roles." unless valid_roles

          unless roles.any? { |role| administrator_role?(role) }
            raise Error, "Stripe App user is not authorized to connect this account."
          end
        end

        def administrator_role?(role)
          if role.key?("id")
            ADMINISTRATOR_ROLE_IDS.include?(role.fetch("id"))
          else
            ADMINISTRATOR_ROLE_NAMES.include?(role.fetch("name"))
          end
        end

        def verify_with_any_secret!(payload, signature)
          raise Error, "Stripe App signature timestamp is invalid." if timestamp_too_far_future?(signature)

          config.signing_secrets.each_with_index do |secret, index|
            return ::Stripe::Webhook::Signature.verify_header(
              payload,
              signature,
              secret.to_s,
              tolerance: TIMESTAMP_TOLERANCE.to_i
            )
          rescue ::Stripe::SignatureVerificationError
            raise Error, "Stripe App signature could not be verified." if index == config.signing_secrets.length - 1
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
