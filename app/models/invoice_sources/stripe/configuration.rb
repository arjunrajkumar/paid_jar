require "cgi"

module InvoiceSources
  class Stripe
    class Configuration
      DEFAULT_HOST = "http://localhost:3000"
      DEFAULT_SCOPE = "read_only"

      def initialize(host: ENV["HOST"])
        @host = host.presence || DEFAULT_HOST
      end

      def configured?
        client_id.present? && secret_key.present?
      end

      def client_id
        credentials[:client_id]
      end

      def secret_key
        credentials[:secret_key]
      end

      def webhook_signing_secret
        credentials[:webhook_signing_secret]
      end

      def webhook_signing_secrets
        Array.wrap(credentials[:webhook_signing_secrets].presence || webhook_signing_secret).compact_blank
      end

      def scope
        DEFAULT_SCOPE
      end

      def redirect_uri
        "#{host.chomp("/")}/stripe/callback"
      end

      def authorization_uri
        URI("https://connect.stripe.com/oauth/authorize")
      end

      def token_uri
        URI("https://connect.stripe.com/oauth/token")
      end

      def deauthorization_uri
        URI("https://connect.stripe.com/oauth/deauthorize")
      end

      def invoices_uri
        URI("https://api.stripe.com/v1/invoices")
      end

      def invoice_uri(invoice_id)
        URI("https://api.stripe.com/v1/invoices/#{CGI.escape(invoice_id)}")
      end

      private
        attr_reader :host

        def credentials
          Rails.application.credentials.stripe || {}
        end
    end
  end
end
