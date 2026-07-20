require "test_helper"

module InvoiceSources
  class Stripe
    class InstallStateTest < ActiveSupport::TestCase
      test "binds a signed expiring state to the account app and browser" do
        account = accounts(:paid_jar)
        token = InstallState.issue(account:, nonce: "browser-nonce", app_id: "com.example.app")

        assert_equal account.id,
          InstallState.verify(token, nonce: "browser-nonce", app_id: "com.example.app")
        assert_nil InstallState.verify(token, nonce: "other-nonce", app_id: "com.example.app")
        assert_nil InstallState.verify(token, nonce: "browser-nonce", app_id: "com.other.app")
        assert_nil InstallState.verify("tampered", nonce: "browser-nonce", app_id: "com.example.app")
      end

      test "expires state" do
        token = InstallState.issue(
          account: accounts(:paid_jar),
          nonce: "browser-nonce",
          app_id: "com.example.app"
        )

        travel 16.minutes do
          assert_nil InstallState.verify(token, nonce: "browser-nonce", app_id: "com.example.app")
        end
      end
    end
  end
end
