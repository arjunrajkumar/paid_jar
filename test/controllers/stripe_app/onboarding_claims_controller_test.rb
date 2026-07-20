require "test_helper"

module StripeApp
  class OnboardingClaimsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @stripe_config = FakeStripeConfiguration.new
      InvoiceSources::Stripe::Configuration.stubs(:new).returns(@stripe_config)
    end

    test "verified Stripe SettingsView request creates a short-lived onboarding claim" do
      payload = app_payload
      signature = stripe_signature(payload)

      assert_difference -> { InvoiceSources::Stripe::InstallationClaim.count }, 1 do
        post stripe_app_onboarding_claims_url,
          params: payload,
          headers: json_headers("Stripe-Signature" => signature)
      end

      assert_response :created
      assert_equal "*", response.headers.fetch("Access-Control-Allow-Origin")
      assert_equal "no-store", response.headers.fetch("Cache-Control")

      onboarding_uri = URI(JSON.parse(response.body).fetch("onboarding_url"))
      token = Rack::Utils.parse_query(onboarding_uri.query).fetch("token")
      claim = InvoiceSources::Stripe::InstallationClaim.active_for_token(token)

      assert_equal "paymentreminder.test", onboarding_uri.host
      assert_equal stripe_app_onboarding_path, onboarding_uri.path
      assert_equal "acct_123", claim.stripe_account_id
      assert_equal "usr_123", claim.stripe_user_id
      assert_equal false, claim.livemode
      assert_equal Digest::SHA256.hexdigest("#{payload}\0#{signature}"), claim.request_digest
      assert_nil claim.account
      assert_nil claim.consumed_at
    end

    test "the same signed Stripe SettingsView request cannot issue a second claim" do
      payload = app_payload
      signature = stripe_signature(payload)

      post stripe_app_onboarding_claims_url,
        params: payload,
        headers: json_headers("Stripe-Signature" => signature)

      assert_response :created

      assert_no_difference -> { InvoiceSources::Stripe::InstallationClaim.count } do
        post stripe_app_onboarding_claims_url,
          params: payload,
          headers: json_headers("Stripe-Signature" => signature)
      end

      assert_response :bad_request
      assert_equal({ "error" => "Stripe App request could not be verified." }, JSON.parse(response.body))
    end

    test "non-admin Stripe user is rejected without issuing a claim" do
      payload = app_payload(stripe_roles: [ { type: "builtIn", name: "View Only" } ])

      assert_no_difference -> { InvoiceSources::Stripe::InstallationClaim.count } do
        post stripe_app_onboarding_claims_url,
          params: payload,
          headers: json_headers("Stripe-Signature" => stripe_signature(payload))
      end

      assert_response :bad_request
      assert_equal({ "error" => "Stripe App request could not be verified." }, JSON.parse(response.body))
    end

    test "invalid Stripe signature is rejected without issuing a claim" do
      payload = app_payload

      assert_no_difference -> { InvoiceSources::Stripe::InstallationClaim.count } do
        post stripe_app_onboarding_claims_url,
          params: payload,
          headers: json_headers("Stripe-Signature" => stripe_signature(payload, secret: "wrong-secret"))
      end

      assert_response :bad_request
      assert_equal({ "error" => "Stripe App request could not be verified." }, JSON.parse(response.body))
      assert_equal "*", response.headers.fetch("Access-Control-Allow-Origin")
    end

    test "request is rejected when its Stripe environment has no platform API key" do
      @stripe_config.configured_modes = [ true ]
      payload = app_payload(livemode: false)

      assert_no_difference -> { InvoiceSources::Stripe::InstallationClaim.count } do
        post stripe_app_onboarding_claims_url,
          params: payload,
          headers: json_headers("Stripe-Signature" => stripe_signature(payload))
      end

      assert_response :bad_request
      assert_equal({ "error" => "Stripe App request could not be verified." }, JSON.parse(response.body))
    end

    test "preflight advertises the signed request headers" do
      options stripe_app_onboarding_claims_url

      assert_response :no_content
      assert_equal "*", response.headers.fetch("Access-Control-Allow-Origin")
      assert_equal "POST, OPTIONS", response.headers.fetch("Access-Control-Allow-Methods")
      assert_equal "Content-Type, Stripe-Signature", response.headers.fetch("Access-Control-Allow-Headers")
      assert_equal "600", response.headers.fetch("Access-Control-Max-Age")
      assert_equal "no-store", response.headers.fetch("Cache-Control")
    end

    private
      def app_payload(livemode: false, stripe_roles: [ { type: "builtIn", name: "Administrator" } ])
        JSON.generate(livemode:, stripe_roles:, user_id: "usr_123", account_id: "acct_123")
      end

      def stripe_signature(payload, secret: @stripe_config.signing_secrets.first)
        timestamp = Time.current.to_i
        digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
        "t=#{timestamp},v1=#{digest}"
      end

      def json_headers(headers = {})
        headers.merge("Content-Type" => "application/json")
      end

      class FakeStripeConfiguration
        attr_accessor :configured_modes

        def initialize
          @configured_modes = [ true, false ]
        end

        def signing_secrets
          [ "absec_test" ]
        end

        def secret_key_configured?(livemode:)
          configured_modes.include?(livemode)
        end

        def host
          "https://paymentreminder.test/"
        end
      end
  end
end
