require "uri"

module InvoiceSources
  class Stripe
    class InstallLink
      def initialize(config: Configuration.new)
        @config = config
      end

      def url(state:)
        uri = URI(config.install_url)
        query = Rack::Utils.parse_query(uri.query).merge(
          "redirect_uri" => config.redirect_uri,
          "state" => state
        )
        uri.query = Rack::Utils.build_query(query)
        uri.to_s
      end

      private
        attr_reader :config
    end
  end
end
