require "test_helper"

module InvoiceSources
  class Stripe
    class DeauthorizationTest < ActiveSupport::TestCase
      test "native deauthorization clears the local connection without legacy OAuth revocation" do
        source = stripe_source(livemode: true, access_token: "deprecated-access-token")
        event = InvoiceSources::Webhooks::Event.create!(
          invoice_source: source,
          provider: :stripe,
          provider_event_id: "evt_native_deauthorization",
          event_type: WebhookEvent::APPLICATION_DEAUTHORIZED_EVENT_TYPE,
          resource_type: "connection",
          resource_id: source.external_account_id,
          occurred_at: Time.current,
          payload: { "livemode" => true }
        )

        event.process!

        assert_predicate source.reload, :disconnected?
        assert_nil source.access_token
        assert_not_requested :post, "https://connect.stripe.com/oauth/deauthorize"
      end

      private
        def stripe_source(livemode:, **attributes)
          accounts(:paid_jar).invoice_sources.create!(
            {
              provider: :stripe,
              status: :active,
              external_account_id: "acct_#{SecureRandom.hex(6)}",
              provider_data: { livemode: livemode }
            }.merge(attributes)
          )
        end
    end
  end
end
