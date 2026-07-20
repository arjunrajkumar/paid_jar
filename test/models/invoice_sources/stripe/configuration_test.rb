require "test_helper"

module InvoiceSources
  class Stripe
    class ConfigurationTest < ActiveSupport::TestCase
      test "declares only the Stripe App permissions the invoice sync uses" do
        assert_equal %w[invoice_read event_read], Configuration.new.permissions
      end

      test "redirect uri defaults to localhost" do
        assert_equal "http://localhost:3000/stripe/callback", Configuration.new.redirect_uri
      end

      test "redirect uri uses the configured host" do
        config = Configuration.new(host: "https://app.example.com/")

        assert_equal "https://app.example.com/stripe/callback", config.redirect_uri
      end

      test "Stripe App credentials determine whether installation is configured" do
        with_stripe_credentials(configured_credentials) do
          assert_predicate Configuration.new, :configured?
        end

        with_stripe_credentials(configured_credentials.except(:install_url)) do
          assert_not_predicate Configuration.new, :configured?
        end

        with_stripe_credentials(configured_credentials.merge(secret_keys: { live: nil, test: "" })) do
          assert_not_predicate Configuration.new, :configured?
        end
      end

      test "selects live and test API keys explicitly" do
        with_stripe_credentials(secret_keys: { live: "sk_live_123", test: "sk_test_123" }) do
          config = Configuration.new

          assert_equal "sk_live_123", config.secret_key(livemode: true)
          assert_equal "sk_test_123", config.secret_key(livemode: false)
        end
      end

      test "keeps App and webhook signing secrets separate and rotation safe" do
        with_stripe_credentials(
          signing_secrets: %w[absec_old absec_new],
          webhook_signing_secrets: {
            live: %w[whsec_live_old whsec_live_new],
            test: [ "whsec_test" ]
          }
        ) do
          config = Configuration.new

          assert_equal %w[absec_old absec_new], config.signing_secrets
          assert_equal %w[whsec_live_old whsec_live_new],
            config.webhook_signing_secrets_for(livemode: true)
          assert_equal [ "whsec_test" ], config.webhook_signing_secrets_for(livemode: false)
        end
      end

      private
        def configured_credentials
          {
            app_id: "com.example.paymentreminder",
            install_url: "https://marketplace.stripe.com/apps/install/link/com.example.paymentreminder",
            signing_secrets: [ "absec_test" ],
            secret_keys: { live: "sk_live_123", test: "sk_test_123" }
          }
        end

        def with_stripe_credentials(stripe)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = stripe
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end
