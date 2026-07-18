require "test_helper"

module InvoiceSources
  class Stripe
    class DeauthorizationWebhookTest < ActiveSupport::TestCase
      setup do
        @source = accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_deauthorized",
          access_token: "deprecated-access-token"
        )
      end

      test "normalizes and processes a verified application deauthorization" do
        payload = deauthorization_payload.to_json

        with_stripe_credentials(webhook_signing_secret: "whsec_test") do
          attributes = WebhookEvent.from_request(
            payload:,
            signature: stripe_signature(payload, "whsec_test")
          ).sole

          assert_equal @source, attributes.fetch(:invoice_source)
          assert_equal "account.application.deauthorized", attributes.fetch(:event_type)
          assert_equal "connection", attributes.fetch(:resource_type)
          assert_equal "acct_deauthorized", attributes.fetch(:resource_id)

          event, = InvoiceSources::Webhooks::Event.record(attributes)
          event.process!
        end

        assert_predicate @source.reload, :disconnected?
        assert_nil @source.access_token
      end

      private
        def deauthorization_payload
          {
            id: "evt_deauthorized",
            type: "account.application.deauthorized",
            account: "acct_deauthorized",
            created: Time.zone.local(2026, 7, 18, 12).to_i,
            data: {
              object: {
                id: "ca_payment_reminder",
                object: "application"
              }
            }
          }
        end

        def stripe_signature(payload, secret)
          timestamp = Time.current.to_i
          digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
          "t=#{timestamp},v1=#{digest}"
        end

        def with_stripe_credentials(**stripe)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = stripe
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end
