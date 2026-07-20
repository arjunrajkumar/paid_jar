require "cgi"

module InvoiceSources
  class Stripe
    class Configuration
      DEFAULT_HOST = "http://localhost:3000"
      PERMISSIONS = %w[invoice_read event_read].freeze

      attr_reader :host

      def initialize(host: ENV["HOST"])
        @host = host.presence || DEFAULT_HOST
      end

      def configured?
        app_id.present? && install_url.present? && signing_secrets.any? &&
          [ true, false ].any? { |livemode| secret_key_configured?(livemode:) }
      end

      def app_id
        credentials[:app_id]
      end

      def install_url
        credentials[:install_url]
      end

      def signing_secrets
        Array.wrap(credentials[:signing_secrets]).compact_blank
      end

      def secret_key(livemode:)
        key = secret_keys[environment_key(livemode)].to_s
        key if key.start_with?(livemode ? "sk_live_" : "sk_test_")
      end

      def secret_key_configured?(livemode:)
        secret_key(livemode:).present?
      end

      def webhook_signing_secrets
        webhook_secrets_by_environment.values.flatten.compact_blank.uniq
      end

      def webhook_signing_secrets_for(livemode:)
        Array.wrap(webhook_secrets_by_environment[environment_key(livemode)]).compact_blank
      end

      def permissions
        PERMISSIONS
      end

      def redirect_uri
        "#{host.chomp("/")}/stripe/callback"
      end

      def invoices_uri
        URI("https://api.stripe.com/v1/invoices")
      end

      def invoice_uri(invoice_id)
        URI("https://api.stripe.com/v1/invoices/#{CGI.escape(invoice_id)}")
      end

      private
        def credentials
          Rails.application.credentials.stripe || {}
        end

        def secret_keys
          normalize_environment_hash(credentials[:secret_keys])
        end

        def webhook_secrets_by_environment
          normalize_environment_hash(credentials[:webhook_signing_secrets])
        end

        def normalize_environment_hash(value)
          value.to_h.deep_symbolize_keys.slice(:live, :test)
        end

        def environment_key(livemode)
          livemode ? :live : :test
        end
    end
  end
end
