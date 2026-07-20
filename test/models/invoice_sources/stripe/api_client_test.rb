require "test_helper"

module InvoiceSources
  class Stripe
    class ApiClientTest < ActiveSupport::TestCase
      test "uses the selected environment key and reads every invoice page" do
        config = fake_config(live_key: "sk_live_123", test_key: "sk_test_123")
        stub_request(:get, "https://api.stripe.com/v1/invoices?limit=100")
          .with(
            basic_auth: [ "sk_test_123", "" ],
            headers: { "Stripe-Account" => "acct_123" }
          )
          .to_return(
            status: 200,
            body: { data: [ { id: "in_1" } ], has_more: true }.to_json
          )
        stub_request(:get, "https://api.stripe.com/v1/invoices?limit=100&starting_after=in_1")
          .with(
            basic_auth: [ "sk_test_123", "" ],
            headers: { "Stripe-Account" => "acct_123" }
          )
          .to_return(
            status: 200,
            body: { data: [ { id: "in_2" } ], has_more: false }.to_json
          )

        payload = ApiClient.new(livemode: false, config:).invoices(stripe_account_id: "acct_123")

        assert_equal [ "in_1", "in_2" ], payload.fetch("data").pluck("id")
      end

      test "fails closed when the selected environment key is missing" do
        client = ApiClient.new(livemode: true, config: fake_config(live_key: nil, test_key: "sk_test_123"))

        error = assert_raises(ApiClient::Error) do
          client.invoices(stripe_account_id: "acct_123")
        end

        assert_match(/not configured/, error.message)
      end

      test "normalizes Stripe API and network failures" do
        config = fake_config(live_key: "sk_live_123", test_key: "sk_test_123")
        stub_request(:get, "https://api.stripe.com/v1/invoices?limit=100")
          .to_return(status: 403, body: { error: { message: "Permission denied" } }.to_json)

        error = assert_raises(ApiClient::Error) do
          ApiClient.new(livemode: true, config:).invoices(stripe_account_id: "acct_123")
        end

        assert_equal "Permission denied", error.message
      end

      test "normalizes temporary network failures" do
        config = fake_config(live_key: "sk_live_123", test_key: "sk_test_123")
        stub_request(:get, "https://api.stripe.com/v1/invoices?limit=100").to_timeout

        error = assert_raises(ApiClient::Error) do
          ApiClient.new(livemode: true, config:).invoices(stripe_account_id: "acct_123")
        end

        assert_match(/temporarily unavailable/, error.message)
      end

      private
        def fake_config(live_key:, test_key:)
          Struct.new(:invoices_uri, :keys) do
            def secret_key(livemode:)
              keys.fetch(livemode)
            end
          end.new(
            URI("https://api.stripe.com/v1/invoices"),
            { true => live_key, false => test_key }
          )
        end
    end
  end
end
