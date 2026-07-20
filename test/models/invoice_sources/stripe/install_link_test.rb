require "test_helper"

module InvoiceSources
  class Stripe
    class InstallLinkTest < ActiveSupport::TestCase
      test "adds the exact callback and state without discarding install-link parameters" do
        config = stub(
          install_url: "https://marketplace.stripe.com/apps/install/link/com.example.app?test=true",
          redirect_uri: "https://app.example.com/stripe/callback"
        )

        uri = URI(InstallLink.new(config:).url(state: "signed-state"))
        query = Rack::Utils.parse_query(uri.query)

        assert_equal "marketplace.stripe.com", uri.host
        assert_equal "true", query.fetch("test")
        assert_equal "https://app.example.com/stripe/callback", query.fetch("redirect_uri")
        assert_equal "signed-state", query.fetch("state")
      end
    end
  end
end
