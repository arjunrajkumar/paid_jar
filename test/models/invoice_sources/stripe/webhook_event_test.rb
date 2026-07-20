require "test_helper"

module InvoiceSources
  class Stripe
    class WebhookEventTest < ActiveSupport::TestCase
      setup do
        @source = accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_123",
          provider_data: { livemode: true }
        )
      end

      test "normalizes verified invoice events for connected Stripe sources" do
        payload = stripe_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          events = WebhookEvent.from_request(
            payload: payload,
            signature: stripe_signature(payload, "whsec_live")
          )

          assert_equal 1, events.size
          event = events.first

          assert_equal @source, event.fetch(:invoice_source)
          assert_equal :stripe, event.fetch(:provider)
          assert_equal "evt_123", event.fetch(:provider_event_id)
          assert_equal "invoice.updated", event.fetch(:event_type)
          assert_equal "invoice", event.fetch(:resource_type)
          assert_equal "in_123", event.fetch(:resource_id)
          assert_equal Time.zone.at(1_788_888_800), event.fetch(:occurred_at)
        end
      end

      test "ignores non invoice events" do
        payload = stripe_payload(type: "customer.updated").to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          events = WebhookEvent.from_request(
            payload: payload,
            signature: stripe_signature(payload, "whsec_live")
          )

          assert_empty events
        end
      end

      test "rejects invalid signatures" do
        payload = stripe_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          assert_raises WebhookEvent::Error do
            WebhookEvent.from_request(payload: payload, signature: stripe_signature(payload, "wrong-secret"))
          end
        end
      end

      test "accepts any configured signing secret" do
        payload = stripe_payload.to_json

        with_stripe_credentials(live: [ "old_secret", "new_secret" ]) do
          events = WebhookEvent.from_request(
            payload: payload,
            signature: stripe_signature(payload, "new_secret")
          )

          assert_equal 1, events.size
          assert_equal "evt_123", events.first.fetch(:provider_event_id)
        end
      end

      test "rejects signatures with future timestamps outside tolerance" do
        payload = stripe_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          assert_raises WebhookEvent::Error do
            WebhookEvent.from_request(
              payload: payload,
              signature: stripe_signature(payload, "whsec_live", timestamp: 10.minutes.from_now.to_i)
            )
          end
        end
      end

      test "uses the test endpoint secret and routes only to test-mode sources" do
        @source.update!(provider_data: { livemode: false })
        payload = stripe_payload(livemode: false).to_json

        with_stripe_credentials(live: [ "whsec_live" ], test: [ "whsec_test" ]) do
          events = WebhookEvent.from_request(
            payload:,
            signature: stripe_signature(payload, "whsec_test"),
            endpoint_livemode: false
          )

          assert_equal @source, events.sole.fetch(:invoice_source)
        end
      end

      test "does not route an event whose mode differs from the webhook endpoint" do
        @source.update!(provider_data: { livemode: false })
        payload = stripe_payload(livemode: false).to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          events = WebhookEvent.from_request(
            payload:,
            signature: stripe_signature(payload, "whsec_live"),
            endpoint_livemode: true
          )

          assert_empty events
        end
      end

      test "does not route live events to a test-mode source" do
        @source.update!(provider_data: { livemode: false })
        payload = stripe_payload(livemode: true).to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          events = WebhookEvent.from_request(
            payload:,
            signature: stripe_signature(payload, "whsec_live")
          )

          assert_empty events
        end
      end

      test "normalizes application authorization events for a known disconnected source" do
        @source.disconnect!
        payload = stripe_payload(
          id: "evt_authorized",
          type: WebhookEvent::APPLICATION_AUTHORIZED_EVENT_TYPE,
          object_id: "ca_payment_reminder",
          object_type: "application"
        ).to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          attributes = WebhookEvent.from_request(
            payload:,
            signature: stripe_signature(payload, "whsec_live")
          ).sole

          assert_equal @source, attributes.fetch(:invoice_source)
          assert_equal "connection", attributes.fetch(:resource_type)
          assert_equal "acct_123", attributes.fetch(:resource_id)
        end
      end

      private
        def stripe_payload(
          id: "evt_123",
          type: "invoice.updated",
          livemode: true,
          object_id: "in_123",
          object_type: "invoice"
        )
          {
            id: id,
            type: type,
            account: "acct_123",
            livemode: livemode,
            created: 1_788_888_800,
            data: {
              object: {
                id: object_id,
                object: object_type
              }
            }
          }
        end

        def stripe_signature(payload, secret, timestamp: Time.current.to_i)
          digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
          "t=#{timestamp},v1=#{digest}"
        end

        def with_stripe_credentials(live: [], test: [])
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = {
            webhook_signing_secrets: {
              live: live,
              test: test
            }
          }
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end
