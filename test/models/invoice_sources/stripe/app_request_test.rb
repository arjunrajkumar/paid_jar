require "test_helper"

module InvoiceSources
  class Stripe
    class AppRequestTest < ActiveSupport::TestCase
      test "verifies the exact signed SettingsView context" do
        payload = app_payload
        context = AppRequest.new(config: config_with("absec_test")).verify!(
          payload:,
          signature: stripe_signature(payload, "absec_test")
        )

        assert_equal "acct_123", context.stripe_account_id
        assert_equal "usr_123", context.stripe_user_id
        assert_equal false, context.livemode
      end

      test "rejects unsigned fields malformed values and stale signatures" do
        request = AppRequest.new(config: config_with("absec_test"))

        invalid_payloads = [
          app_payload(extra: "bad"),
          app_payload(livemode: "false"),
          app_payload(user_id: "bad")
        ]

        invalid_payloads.each do |payload|
          assert_raises(AppRequest::Error) do
            request.verify!(payload:, signature: stripe_signature(payload, "absec_test"))
          end
        end

        payload = app_payload(livemode: true)
        assert_raises(AppRequest::Error) do
          request.verify!(
            payload:,
            signature: stripe_signature(payload, "absec_test", timestamp: 10.minutes.ago)
          )
        end
      end

      test "accepts stable administrator role ids when Stripe includes them" do
        roles = [
          { type: "builtIn", id: "admin", name: "Renamed administrator" },
          { type: "builtIn", id: "super_admin", name: "Renamed super administrator" }
        ]

        roles.each do |role|
          payload = app_payload(stripe_roles: [ role ])

          assert AppRequest.new(config: config_with("absec_test")).verify!(
            payload:,
            signature: stripe_signature(payload, "absec_test")
          )
        end
      end

      test "falls back to exact administrator role names when Stripe omits role ids" do
        [ "Administrator", "Super Administrator" ].each do |role_name|
          payload = app_payload(stripe_roles: [ { type: "builtIn", name: role_name } ])

          assert AppRequest.new(config: config_with("absec_test")).verify!(
            payload:,
            signature: stripe_signature(payload, "absec_test")
          )
        end
      end

      test "rejects unauthorized or malformed roles" do
        invalid_roles = [
          [],
          [ { type: "custom", name: "Administrator" } ],
          [ { type: "builtIn", id: "developer", name: "Administrator" } ],
          [ { type: "builtIn", id: 123, name: "Administrator" } ],
          [ { type: "builtIn", name: "Developer" } ]
        ]

        invalid_roles.each do |roles|
          payload = app_payload(stripe_roles: roles)

          assert_raises(AppRequest::Error) do
            AppRequest.new(config: config_with("absec_test")).verify!(
              payload:,
              signature: stripe_signature(payload, "absec_test")
            )
          end
        end
      end

      private
        def app_payload(**overrides)
          JSON.generate({
            livemode: false,
            stripe_roles: [ { type: "builtIn", name: "Administrator" } ],
            user_id: "usr_123",
            account_id: "acct_123"
          }.merge(overrides))
        end

        def config_with(secret)
          stub(signing_secrets: [ secret ])
        end

        def stripe_signature(payload, secret, timestamp: Time.current)
          digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp.to_i}.#{payload}")
          "t=#{timestamp.to_i},v1=#{digest}"
        end
    end
  end
end
