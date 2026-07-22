require "test_helper"

class EmailConnection::Gmail::OauthStateTest < ActiveSupport::TestCase
  test "verifies the initiating account and browser nonce" do
    account = accounts(:paid_jar)
    token = EmailConnection::Gmail::OauthState.issue(account:, nonce: "browser-nonce")

    assert EmailConnection::Gmail::OauthState.valid?(token, account:, nonce: "browser-nonce")
    refute EmailConnection::Gmail::OauthState.valid?(token, account: Account.create!(name: "Other"), nonce: "browser-nonce")
    refute EmailConnection::Gmail::OauthState.valid?(token, account:, nonce: "different-nonce")
    refute EmailConnection::Gmail::OauthState.valid?("tampered", account:, nonce: "browser-nonce")
  end
end
