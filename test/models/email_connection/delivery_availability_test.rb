require "test_helper"

class EmailConnection::DeliveryAvailabilityTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @connection = email_connections(:paid_jar_gmail)
  end

  test "returns the active connection when its sender belongs to the account" do
    result = availability

    assert_predicate result, :ready?
    assert_equal @connection, result.connection
    assert_nil result.reason
  end

  test "reports a missing email connection" do
    account = Account.create!(name: "Account Without Email")

    result = availability(account:)

    assert_not_predicate result, :ready?
    assert_nil result.connection
    assert_equal "missing_email_connection", result.reason
  end

  test "reports an inactive email connection as missing" do
    @account.email_connection
    EmailConnection.where(id: @connection.id).update_all(status: :disconnected)

    result = availability

    assert_not_predicate result, :ready?
    assert_nil result.connection
    assert_equal "missing_email_connection", result.reason
  end

  test "rejects a connection belonging to another account" do
    other_account = Account.create!(name: "Other Delivery Account")
    other_connection = other_account.create_email_connection!(
      provider: :gmail,
      provider_account_id: "google-account-availability",
      connected_email: "billing@other.example",
      access_token: "access-token",
      refresh_token: "refresh-token",
      token_expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
      inbound_cursor: "100",
      status: :active
    )
    @account.stubs(:email_connection).returns(other_connection)

    result = availability

    assert_not_predicate result, :ready?
    assert_nil result.connection
    assert_equal "missing_email_connection", result.reason
  end

  test "reports when the configured sender does not match the connection" do
    @account.update_column(:invoice_reminder_from_email, "other-sender@example.com")

    result = availability

    assert_not_predicate result, :ready?
    assert_nil result.connection
    assert_equal "sender_address_mismatch", result.reason
  end

  test "does not log unavailable connections" do
    @connection.update!(status: :disconnected)
    Rails.logger.expects(:info).never
    Rails.logger.expects(:warn).never
    Rails.logger.expects(:error).never

    availability
  end

  private
    def availability(account: @account)
      EmailConnection::DeliveryAvailability.call(account:)
    end
end
