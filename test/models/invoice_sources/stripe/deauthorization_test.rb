require "test_helper"

module InvoiceSources
  class Stripe
    class DeauthorizationTest < ActiveSupport::TestCase
      test "OAuth client deauthorizes the connected account" do
        with_stripe_credentials(client_id: "ca_123", secret_key: "sk_test_123") do
          stub_request(:post, "https://connect.stripe.com/oauth/deauthorize")
            .with(
              basic_auth: [ "sk_test_123", "" ],
              body: {
                "client_id" => "ca_123",
                "stripe_user_id" => "acct_123"
              }
            )
            .to_return(status: 200, body: { stripe_user_id: "acct_123" }.to_json)

          response = OauthClient.new.deauthorize(stripe_account_id: "acct_123")

          assert_equal "acct_123", response.fetch("stripe_user_id")
        end
      end

      test "disconnect revokes Stripe access before clearing local credentials" do
        source = accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_disconnect",
          access_token: "deprecated-access-token"
        )
        client = FakeDeauthorizationClient.new
        OauthClient.stubs(:new).returns(client)

        InvoiceSources::Stripe.new(source).disconnect!

        assert_equal "acct_disconnect", client.deauthorized_account_id
        assert_predicate source.reload, :disconnected?
        assert_nil source.access_token
      end

      test "disconnect keeps the local connection active when Stripe revocation fails" do
        source = accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_disconnect_failure",
          access_token: "deprecated-access-token"
        )
        client = FakeDeauthorizationClient.new(error: OauthClient::Error.new("Stripe unavailable"))
        OauthClient.stubs(:new).returns(client)

        assert_raises OauthClient::Error do
          InvoiceSources::Stripe.new(source).disconnect!
        end

        assert_predicate source.reload, :active?
        assert_equal "deprecated-access-token", source.access_token
      end

      private
        def with_stripe_credentials(**stripe)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = stripe
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end

      class FakeDeauthorizationClient
        attr_reader :config, :deauthorized_account_id

        def initialize(error: nil)
          @error = error
          @config = Struct.new(:configured?).new(true)
        end

        def deauthorize(stripe_account_id:)
          raise @error if @error

          @deauthorized_account_id = stripe_account_id
        end
      end
    end
  end
end
