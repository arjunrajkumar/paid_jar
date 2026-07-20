require "test_helper"

module InvoiceSources
  module Webhooks
    class StripeControllerTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      setup do
        @source = accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_123",
          provider_data: { livemode: true }
        )
      end

      teardown do
        clear_enqueued_jobs
        clear_performed_jobs
      end

      test "creates and enqueues a verified webhook event" do
        payload = stripe_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          assert_difference -> { InvoiceSources::Webhooks::Event.count }, 1 do
            assert_enqueued_with(job: InvoiceSources::Webhooks::ProcessJob) do
              post invoice_sources_webhooks_stripe_url,
                params: payload,
                headers: json_headers("Stripe-Signature" => stripe_signature(payload, "whsec_live"))
            end
          end
        end

        assert_response :ok
        event = InvoiceSources::Webhooks::Event.last
        assert_equal @source, event.invoice_source
        assert_equal "evt_123", event.provider_event_id
        assert_equal "in_123", event.resource_id
      end

      test "does not enqueue duplicate events" do
        payload = stripe_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          post invoice_sources_webhooks_stripe_url,
            params: payload,
            headers: json_headers("Stripe-Signature" => stripe_signature(payload, "whsec_live"))

          assert_no_difference -> { InvoiceSources::Webhooks::Event.count } do
            assert_no_enqueued_jobs do
              post invoice_sources_webhooks_stripe_url,
                params: payload,
                headers: json_headers("Stripe-Signature" => stripe_signature(payload, "whsec_live"))
            end
          end
        end

        assert_response :ok
      end

      test "rejects invalid signatures" do
        payload = stripe_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ]) do
          assert_no_difference -> { InvoiceSources::Webhooks::Event.count } do
            post invoice_sources_webhooks_stripe_url,
              params: payload,
              headers: json_headers("Stripe-Signature" => stripe_signature(payload, "wrong-secret"))
          end
        end

        assert_response :bad_request
      end

      test "uses a separate signing secret for test-mode webhooks" do
        @source.update!(provider_data: { livemode: false })
        payload = stripe_payload(livemode: false).to_json

        with_stripe_credentials(live: [ "whsec_live" ], test: [ "whsec_test" ]) do
          assert_difference -> { InvoiceSources::Webhooks::Event.count }, 1 do
            assert_enqueued_with(job: InvoiceSources::Webhooks::ProcessJob) do
              post invoice_sources_webhooks_stripe_test_url,
                params: payload,
                headers: json_headers("Stripe-Signature" => stripe_signature(payload, "whsec_test"))
            end
          end
        end

        assert_response :ok
        assert_equal @source, InvoiceSources::Webhooks::Event.last.invoice_source
      end

      test "rejects a test secret at the live webhook endpoint" do
        payload = stripe_payload.to_json

        with_stripe_credentials(live: [ "whsec_live" ], test: [ "whsec_test" ]) do
          assert_no_difference -> { InvoiceSources::Webhooks::Event.count } do
            post invoice_sources_webhooks_stripe_url,
              params: payload,
              headers: json_headers("Stripe-Signature" => stripe_signature(payload, "whsec_test"))
          end
        end

        assert_response :bad_request
      end

      test "ignores events whose mode differs from the endpoint" do
        @source.update!(provider_data: { livemode: false })
        payload = stripe_payload(livemode: false).to_json

        with_stripe_credentials(live: [ "whsec_live" ], test: [ "whsec_test" ]) do
          assert_no_difference -> { InvoiceSources::Webhooks::Event.count } do
            assert_no_enqueued_jobs do
              post invoice_sources_webhooks_stripe_url,
                params: payload,
                headers: json_headers("Stripe-Signature" => stripe_signature(payload, "whsec_live"))
            end
          end
        end

        assert_response :ok
      end

      private
        def stripe_payload(livemode: true)
          {
            id: "evt_123",
            type: "invoice.updated",
            account: "acct_123",
            livemode: livemode,
            created: 1_788_888_800,
            data: {
              object: {
                id: "in_123",
                object: "invoice"
              }
            }
          }
        end

        def stripe_signature(payload, secret)
          timestamp = Time.current.to_i
          digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
          "t=#{timestamp},v1=#{digest}"
        end

        def json_headers(headers = {})
          headers.merge("Content-Type" => "application/json")
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
