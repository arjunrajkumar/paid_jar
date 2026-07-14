require "test_helper"

module InvoiceSources
  class Xero
    class ConfigurationTest < ActiveSupport::TestCase
      test "default scopes request identity and read-only accounting access" do
        with_xero_credentials(client_id: "client-123", client_secret: "secret-123") do
          config = Configuration.new

          assert_equal "openid profile email accounting.invoices.read accounting.contacts.read offline_access", config.scopes
        end
      end

      test "redirect uri defaults to localhost" do
        assert_equal "http://localhost:3000/xero/callback", Configuration.new.redirect_uri
      end

      test "redirect uri uses the configured host" do
        config = Configuration.new(host: "https://app.example.com/")

        assert_equal "https://app.example.com/xero/callback", config.redirect_uri
      end

      test "credentials determine whether Xero is configured" do
        with_xero_credentials(
          client_id: "client-123",
          client_secret: "secret-123"
        ) do
          assert_predicate Configuration.new, :configured?
        end

        with_xero_credentials(client_id: "client-123") do
          assert_not_predicate Configuration.new, :configured?
        end
      end

      private
        def with_xero_credentials(**xero)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.xero = xero
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end
