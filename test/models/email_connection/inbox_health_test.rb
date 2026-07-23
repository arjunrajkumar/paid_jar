require "test_helper"

class EmailConnection::InboxHealthTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @connection = email_connections(:paid_jar_gmail)
  end

  test "reports receiving and sending health separately without provider internals" do
    at = Time.zone.local(2026, 7, 23, 12)
    @connection.update!(
      last_inbound_synced_at: at - 20.minutes,
      last_inbound_error: nil,
      last_error: nil
    )

    health = EmailConnection::InboxHealth.call(account: @account, at:)

    assert_equal "healthy", health.receiving.state
    assert_equal "healthy", health.sending.state
    assert_equal @connection.connected_email, health.connected_email
    assert_equal @connection.last_inbound_synced_at, health.last_successful_inbound_sync_at
    assert_not health.action_required?
    assert_not_respond_to health, :provider_account_id
    assert_not_respond_to health, :credential_generation
  end

  test "reports delayed inbound sync while keeping sending healthy" do
    at = Time.zone.local(2026, 7, 23, 12)
    @connection.update!(last_inbound_synced_at: at - 2.hours)

    health = EmailConnection::InboxHealth.call(account: @account, at:)

    assert_equal "delayed", health.receiving.state
    assert_equal "healthy", health.sending.state
    assert health.receiving.action_required
  end

  test "reports a safe not-connected state" do
    @connection.destroy!

    health = EmailConnection::InboxHealth.call(account: @account)

    assert_equal "not_connected", health.receiving.state
    assert_equal "not_connected", health.sending.state
    assert health.action_required?
  end
end
