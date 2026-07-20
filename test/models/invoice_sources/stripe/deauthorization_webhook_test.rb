require "test_helper"

module InvoiceSources
  class Stripe
    class DeauthorizationWebhookTest < ActiveSupport::TestCase
      setup do
        @source = accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_deauthorized",
          access_token: "deprecated-access-token",
          provider_data: {
            authorization_type: InvoiceSources::Stripe::AUTHORIZATION_TYPE,
            livemode: true
          }
        )
      end

      test "normalizes and processes a verified application deauthorization" do
        payload = deauthorization_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          attributes = WebhookEvent.from_request(
            payload:,
            signature: stripe_signature(payload, "whsec_live")
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

      test "a verified application authorization reactivates a known disconnected source" do
        @source.disconnect!
        payload = authorization_payload.to_json

        travel_to Time.zone.local(2026, 7, 20, 12) do
          with_stripe_credentials(live: [ "whsec_live" ]) do
            attributes = WebhookEvent.from_request(
              payload:,
              signature: stripe_signature(payload, "whsec_live")
            ).sole

            assert_equal @source, attributes.fetch(:invoice_source)
            assert_equal "account.application.authorized", attributes.fetch(:event_type)
            assert_equal "connection", attributes.fetch(:resource_type)

            event, = InvoiceSources::Webhooks::Event.record(attributes)
            event.process!
          end

          assert_predicate @source.reload, :active?
          assert_equal Time.current.iso8601, @source.provider_data.fetch("authorized_at")
        end
      end

      test "records deauthorization for a known disconnected source" do
        @source.disconnect!
        payload = deauthorization_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          attributes = WebhookEvent.from_request(
            payload:,
            signature: stripe_signature(payload, "whsec_live")
          ).sole
          event, = InvoiceSources::Webhooks::Event.record(attributes)
          event.process!

          assert_predicate event, :processed?
          assert_predicate @source.reload, :disconnected?
          assert_equal WebhookEvent::APPLICATION_DEAUTHORIZED_EVENT_TYPE,
            @source.provider_data.fetch(InvoiceSources::Stripe::LIFECYCLE_EVENT_TYPE_KEY)
        end
      end

      test "an older authorization event cannot undo a newer deauthorization" do
        deauthorization = lifecycle_event(
          id: "evt_newer_deauthorization",
          type: WebhookEvent::APPLICATION_DEAUTHORIZED_EVENT_TYPE,
          occurred_at: 1.minute.ago
        )
        authorization = lifecycle_event(
          id: "evt_older_authorization",
          type: WebhookEvent::APPLICATION_AUTHORIZED_EVENT_TYPE,
          occurred_at: 2.minutes.ago
        )

        deauthorization.process!
        authorization.process!

        assert_predicate @source.reload, :disconnected?
        assert_predicate authorization.reload, :ignored?
        assert_equal WebhookEvent::APPLICATION_DEAUTHORIZED_EVENT_TYPE,
          @source.provider_data.fetch(InvoiceSources::Stripe::LIFECYCLE_EVENT_TYPE_KEY)
      end

      test "an older deauthorization event cannot undo a newer authorization" do
        @source.disconnect!
        authorization = lifecycle_event(
          id: "evt_newer_authorization",
          type: WebhookEvent::APPLICATION_AUTHORIZED_EVENT_TYPE,
          occurred_at: 1.minute.ago
        )
        deauthorization = lifecycle_event(
          id: "evt_older_deauthorization",
          type: WebhookEvent::APPLICATION_DEAUTHORIZED_EVENT_TYPE,
          occurred_at: 2.minutes.ago
        )

        authorization.process!
        deauthorization.process!

        assert_predicate @source.reload, :active?
        assert_predicate deauthorization.reload, :ignored?
        assert_equal WebhookEvent::APPLICATION_AUTHORIZED_EVENT_TYPE,
          @source.provider_data.fetch(InvoiceSources::Stripe::LIFECYCLE_EVENT_TYPE_KEY)
      end

      private
        def deauthorization_payload
          {
            id: "evt_deauthorized",
            type: "account.application.deauthorized",
            account: "acct_deauthorized",
            livemode: true,
            created: Time.zone.local(2026, 7, 18, 12).to_i,
            data: {
              object: {
                id: "ca_payment_reminder",
                object: "application"
              }
            }
          }
        end

        def authorization_payload
          {
            id: "evt_authorized",
            type: "account.application.authorized",
            account: "acct_deauthorized",
            livemode: true,
            created: Time.zone.local(2026, 7, 20, 12).to_i,
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

        def lifecycle_event(id:, type:, occurred_at:)
          InvoiceSources::Webhooks::Event.create!(
            invoice_source: @source,
            provider: :stripe,
            provider_event_id: id,
            event_type: type,
            resource_type: "connection",
            resource_id: @source.external_account_id,
            occurred_at:,
            payload: { "livemode" => true }
          )
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
