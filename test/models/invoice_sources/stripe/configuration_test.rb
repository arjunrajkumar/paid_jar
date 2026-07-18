require "test_helper"

module InvoiceSources
  class Stripe
    class ConfigurationTest < ActiveSupport::TestCase
      test "default scope requests read-only account access" do
        with_stripe_credentials(client_id: "ca_123", secret_key: "sk_test_123") do
          config = Configuration.new

          assert_equal "read_only", config.scope
        end
      end

      test "redirect uri defaults to localhost" do
        assert_equal "http://localhost:3000/stripe/callback", Configuration.new.redirect_uri
      end

      test "redirect uri uses the configured host" do
        config = Configuration.new(host: "https://app.example.com/")

        assert_equal "https://app.example.com/stripe/callback", config.redirect_uri
      end

      test "credentials determine whether Stripe is configured" do
        with_stripe_credentials(
          client_id: "ca_123",
          secret_key: "sk_test_123"
        ) do
          assert_predicate Configuration.new, :configured?
        end

        with_stripe_credentials(client_id: "ca_123") do
          assert_not_predicate Configuration.new, :configured?
        end
      end

      test "webhook signing secrets can be configured as one secret or many" do
        with_stripe_credentials(webhook_signing_secret: "whsec_one") do
          assert_equal [ "whsec_one" ], Configuration.new.webhook_signing_secrets
        end

        with_stripe_credentials(webhook_signing_secrets: [ "whsec_old", "whsec_new" ]) do
          assert_equal [ "whsec_old", "whsec_new" ], Configuration.new.webhook_signing_secrets
        end
      end

      private
        def with_stripe_credentials(**stripe)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = stripe
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end
