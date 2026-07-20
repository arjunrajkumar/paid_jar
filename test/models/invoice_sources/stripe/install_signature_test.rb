require "test_helper"

module InvoiceSources
  class Stripe
    class InstallSignatureTest < ActiveSupport::TestCase
      test "verifies Stripe's exact ordered installation payload" do
        verifier = InstallSignature.new(config: config_with("absec_test"))
        payload = JSON.generate(state: "state", user_id: "usr_123", account_id: "acct_123")

        assert verifier.verify!(
          state: "state",
          user_id: "usr_123",
          account_id: "acct_123",
          signature: stripe_signature(payload, "absec_test")
        )
      end

      test "rejects replayed stale and future-dated signatures" do
        verifier = InstallSignature.new(config: config_with("absec_test"))
        payload = JSON.generate(state: "state", user_id: "usr_123", account_id: "acct_123")

        [ 10.minutes.ago, 10.minutes.from_now ].each do |timestamp|
          assert_raises InstallSignature::Error do
            verifier.verify!(
              state: "state",
              user_id: "usr_123",
              account_id: "acct_123",
              signature: stripe_signature(payload, "absec_test", timestamp:)
            )
          end
        end
      end

      private
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
