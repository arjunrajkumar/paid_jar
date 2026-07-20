require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

module InvoiceSources
  class Stripe
    class ApiClient
      class Error < StandardError; end
      class AuthorizationError < Error; end

      OPEN_TIMEOUT = 5.seconds
      READ_TIMEOUT = 20.seconds

      attr_reader :config, :livemode

      def initialize(livemode:, config: Configuration.new)
        @config = config
        @livemode = livemode
      end

      def invoices(stripe_account_id:)
        data = []
        starting_after = nil

        loop do
          payload = list_invoices(stripe_account_id:, starting_after:)
          batch = Array(payload["data"])
          data.concat(batch)

          break unless payload["has_more"] && batch.any?

          starting_after = batch.last.fetch("id")
        end

        { "data" => data }
      end

      def invoice(stripe_account_id:, invoice_id:)
        get_json(config.invoice_uri(invoice_id), stripe_account_id:)
      end

      def verify_access!(stripe_account_id:)
        uri = config.invoices_uri.dup
        uri.query = Rack::Utils.build_query(limit: 1)
        get_json(uri, stripe_account_id:)
        true
      end

      private
        def list_invoices(stripe_account_id:, starting_after:)
          uri = config.invoices_uri.dup
          query = { limit: 100 }
          query[:starting_after] = starting_after if starting_after.present?
          uri.query = Rack::Utils.build_query(query)

          get_json(uri, stripe_account_id:)
        end

        def get_json(uri, stripe_account_id:)
          request = Net::HTTP::Get.new(uri)
          request.basic_auth(secret_key, "")
          request["Accept"] = "application/json"
          request["Stripe-Account"] = stripe_account_id

          request_json(uri, request)
        end

        def secret_key
          config.secret_key(livemode:) || raise(Error, "Stripe API credentials are not configured for this environment.")
        end

        def request_json(uri, request)
          response = Net::HTTP.start(
            uri.hostname,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: OPEN_TIMEOUT,
            read_timeout: READ_TIMEOUT
          ) { |http| http.request(request) }

          body = response.body.presence || "{}"
          parsed_body = JSON.parse(body)

          return parsed_body if response.is_a?(Net::HTTPSuccess)

          message = parsed_body.dig("error", "message") || response.message
          if response.is_a?(Net::HTTPUnauthorized) || response.is_a?(Net::HTTPForbidden)
            raise AuthorizationError, message
          end

          raise Error, message
        rescue JSON::ParserError
          raise Error, "Stripe returned an invalid response."
        rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => error
          raise Error, "Stripe is temporarily unavailable: #{error.class.name}"
        end
    end
  end
end
