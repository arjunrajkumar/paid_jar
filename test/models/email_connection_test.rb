require "test_helper"

class EmailConnectionTest < ActiveSupport::TestCase
  test "allows only one email connection per account" do
    account = Account.create!(name: "Unique Connection Account")

    account.create_email_connection!(gmail_attributes)
    duplicate = EmailConnection.new(gmail_attributes.merge(account:))

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:account_id], "has already been taken"
  end

  test "encrypts Gmail tokens at rest" do
    connection = Account.create!(name: "Encrypted Connection Account")
      .create_email_connection!(gmail_attributes)
    stored_tokens = ApplicationRecord.connection.select_one(<<~SQL.squish)
      SELECT access_token, refresh_token
      FROM email_connections
      WHERE id = #{connection.id}
    SQL

    assert_equal "access-token", connection.access_token
    assert_equal "refresh-token", connection.refresh_token
    refute_equal "access-token", stored_tokens.fetch("access_token")
    refute_equal "refresh-token", stored_tokens.fetch("refresh_token")
  end

  test "reconnection preserves the existing refresh token when Google omits it" do
    connection = Account.create!(name: "Reconnect Account")
      .create_email_connection!(gmail_attributes)
    previous_generation = connection.credential_generation

    connection.connect_gmail!(
      email: "billing@example.com",
      name: "Billing Team",
      provider_account_id: "google-account-123",
      history_id: "200",
      access_token: "new-access-token",
      refresh_token: nil,
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )

    assert_equal "new-access-token", connection.access_token
    assert_equal "refresh-token", connection.refresh_token
    assert_equal previous_generation + 1, connection.credential_generation
    assert_predicate connection, :active?
  end

  test "normalizes short and canonical Google identity scope names" do
    connection = Account.create!(name: "Canonical Scope Account")
      .create_email_connection!(
        gmail_attributes.merge(
          scopes: [
            "email",
            EmailConnection::Gmailable::PROFILE_SCOPE,
            EmailConnection::Gmailable::SEND_SCOPE,
            EmailConnection::Gmailable::READ_SCOPE
          ]
        )
      )

    assert_equal EmailConnection::Gmailable::REQUIRED_SCOPES, connection.scopes
    assert_predicate connection, :gmail_ready?
  end

  test "refreshes an access token that expires within five minutes" do
    connection = Account.create!(name: "Refresh Account").create_email_connection!(
      gmail_attributes.merge(token_expires_at: 4.minutes.from_now)
    )
    oauth_client = mock
    oauth_client.expects(:refresh_token).with(refresh_token: "refresh-token").returns(
      "access_token" => "fresh-token",
      "expires_in" => 3600
    )

    connection.refresh_gmail_access_token_if_needed!(oauth_client:)

    assert_equal "fresh-token", connection.access_token
    assert_in_delta 1.hour.from_now, connection.token_expires_at, 1.second
  end

  test "does not apply a completed refresh after the same Gmail identity reconnects" do
    connection = Account.create!(name: "Same Identity Refresh Race")
      .create_email_connection!(gmail_attributes.merge(token_expires_at: 1.minute.ago))
    expected_generation = connection.credential_generation
    oauth_client = Object.new
    oauth_client.define_singleton_method(:refresh_token) do |refresh_token:|
      raise "unexpected refresh token" unless refresh_token == "refresh-token"

      connection.connect_gmail!(
        email: "billing@example.com",
        name: "Reauthorized Billing",
        provider_account_id: "google-account-123",
        history_id: "200",
        access_token: "reauthorized-access",
        refresh_token: "reauthorized-refresh",
        expires_at: 1.hour.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
      {
        "access_token" => "stale-refreshed-access",
        "refresh_token" => "stale-refreshed-refresh",
        "expires_in" => 3600
      }
    end

    assert_raises EmailConnection::Errors::CredentialChanged do
      connection.refresh_gmail_access_token_if_needed!(
        oauth_client:,
        provider_account_id: "google-account-123",
        credential_generation: expected_generation
      )
    end

    assert_equal "reauthorized-access", connection.reload.access_token
    assert_equal "reauthorized-refresh", connection.refresh_token
    assert_equal expected_generation + 1, connection.credential_generation
    assert_predicate connection, :active?
  end

  test "does not let an older same-generation refresh overwrite newer tokens" do
    connection = Account.create!(name: "Concurrent Refresh Race")
      .create_email_connection!(gmail_attributes.merge(token_expires_at: 1.minute.ago))
    oauth_client = Object.new
    oauth_client.define_singleton_method(:refresh_token) do |refresh_token:|
      raise "unexpected refresh token" unless refresh_token == "refresh-token"

      connection.update!(
        access_token: "winning-access",
        refresh_token: "winning-refresh",
        token_expires_at: 1.hour.from_now
      )
      {
        "access_token" => "stale-access",
        "refresh_token" => "stale-refresh",
        "expires_in" => 3600
      }
    end

    result = connection.refresh_gmail_access_token_if_needed!(oauth_client:)

    assert_equal "winning-access", result
    assert_equal "winning-access", connection.reload.access_token
    assert_equal "winning-refresh", connection.refresh_token
    assert_predicate connection, :active?
  end

  test "ignores an old refresh failure after newer same-generation tokens win" do
    connection = Account.create!(name: "Concurrent Refresh Failure")
      .create_email_connection!(gmail_attributes.merge(token_expires_at: 1.minute.ago))
    oauth_client = Object.new
    oauth_client.define_singleton_method(:refresh_token) do |refresh_token:|
      raise "unexpected refresh token" unless refresh_token == "refresh-token"

      connection.update!(
        access_token: "winning-access",
        refresh_token: "winning-refresh",
        token_expires_at: 1.hour.from_now
      )
      raise EmailConnection::Errors::AuthenticationError, "stale refresh failure"
    end

    result = connection.refresh_gmail_access_token_if_needed!(oauth_client:)

    assert_equal "winning-access", result
    assert_equal "winning-access", connection.reload.access_token
    assert_equal "winning-refresh", connection.refresh_token
    assert_predicate connection, :active?
    assert_nil connection.last_error
  end

  test "marks the current Gmail credential generation errored after a revoked refresh" do
    connection = Account.create!(name: "Revoked Current Refresh")
      .create_email_connection!(gmail_attributes.merge(token_expires_at: 1.minute.ago))
    oauth_client = mock
    oauth_client.expects(:refresh_token)
      .with(refresh_token: "refresh-token")
      .raises(EmailConnection::Errors::AuthenticationError, "refresh_revoked")

    assert_raises EmailConnection::Errors::AuthenticationError do
      connection.refresh_gmail_access_token_if_needed!(oauth_client:)
    end

    assert_predicate connection.reload, :errored?
    assert_equal "gmail_authentication_failed", connection.last_error
  end

  test "an errored Gmail connection requires a new refresh token when reconnecting" do
    connection = Account.create!(name: "Errored Reconnect")
      .create_email_connection!(gmail_attributes)
    connection.update!(status: :errored, last_error: "gmail_authentication_failed")

    assert_raises EmailConnection::Errors::AuthenticationError do
      connection.connect_gmail!(
        email: "billing@example.com",
        name: "Billing Team",
        provider_account_id: "google-account-123",
        history_id: "200",
        access_token: "new-access-token",
        refresh_token: nil,
        expires_at: 1.hour.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
    end

    assert_predicate connection.reload, :errored?
    assert_equal "refresh-token", connection.refresh_token
  end

  test "does not mark a replacement Gmail identity errored for an old refresh failure" do
    connection = Account.create!(name: "Replacement Identity Refresh Race")
      .create_email_connection!(gmail_attributes.merge(token_expires_at: 1.minute.ago))
    expected_generation = connection.credential_generation
    oauth_client = Object.new
    oauth_client.define_singleton_method(:refresh_token) do |refresh_token:|
      raise "unexpected refresh token" unless refresh_token == "refresh-token"

      connection.connect_gmail!(
        email: "replacement@example.com",
        name: "Replacement Billing",
        provider_account_id: "google-account-999",
        history_id: "900",
        access_token: "replacement-access",
        refresh_token: "replacement-refresh",
        expires_at: 1.hour.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
      raise EmailConnection::Errors::AuthenticationError, "old_refresh_revoked"
    end

    assert_raises EmailConnection::Errors::CredentialChanged do
      connection.refresh_gmail_access_token_if_needed!(
        oauth_client:,
        provider_account_id: "google-account-123",
        credential_generation: expected_generation
      )
    end

    assert_equal "google-account-999", connection.reload.provider_account_id
    assert_equal "replacement-access", connection.access_token
    assert_predicate connection, :active?
    assert_nil connection.last_error
  end

  test "does not mark a disconnected Gmail connection errored for an old refresh failure" do
    connection = Account.create!(name: "Disconnected Refresh Race")
      .create_email_connection!(gmail_attributes.merge(token_expires_at: 1.minute.ago))
    expected_generation = connection.credential_generation
    oauth_client = Object.new
    oauth_client.define_singleton_method(:refresh_token) do |refresh_token:|
      raise "unexpected refresh token" unless refresh_token == "refresh-token"

      connection.disconnect!
      raise EmailConnection::Errors::AuthenticationError, "old_refresh_revoked"
    end

    assert_raises EmailConnection::Errors::CredentialChanged do
      connection.refresh_gmail_access_token_if_needed!(
        oauth_client:,
        provider_account_id: "google-account-123",
        credential_generation: expected_generation
      )
    end

    assert_predicate connection.reload, :disconnected?
    assert_nil connection.last_error
    assert_equal expected_generation + 1, connection.credential_generation
  end

  test "active Gmail requires a stable identity and complete scopes" do
    missing_identity = EmailConnection.new(gmail_attributes.except(:provider_account_id))
    missing_read_scope = EmailConnection.new(
      gmail_attributes.merge(scopes: EmailConnection::Gmailable::REQUIRED_SCOPES - [ EmailConnection::Gmailable::READ_SCOPE ])
    )

    assert_not missing_identity.valid?
    assert_includes missing_identity.errors[:provider_account_id], "can't be blank"
    assert_not missing_read_scope.valid?
    assert_includes missing_read_scope.errors[:scopes], "must include Gmail send and readonly access"
  end

  test "same Google identity preserves sync state when the email changes" do
    connection = Account.create!(name: "Renamed Gmail account")
      .create_email_connection!(
        gmail_attributes.merge(last_inbound_synced_at: 1.day.ago)
      )
    last_synced_at = connection.last_inbound_synced_at
    pending_receipt = connection.email_message_receipts.create!(
      account: connection.account,
      provider_message_id: "same-account-old-generation",
      discovered_at: Time.current
    )

    connection.connect_gmail!(
      email: "renamed@example.com",
      name: "Renamed Billing",
      provider_account_id: "google-account-123",
      history_id: "999",
      access_token: "new-access-token",
      refresh_token: nil,
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )

    assert_equal "renamed@example.com", connection.connected_email
    assert_equal "refresh-token", connection.refresh_token
    assert_equal "100", connection.inbound_cursor
    assert_equal last_synced_at, connection.last_inbound_synced_at
    assert_predicate pending_receipt.reload, :status_pending?
    assert_equal connection.credential_generation, pending_receipt.email_connection_generation
    assert_empty pending_receipt.metadata
  end

  test "different Google identity resets synchronization state" do
    connection = Account.create!(name: "Replacement Gmail account")
      .create_email_connection!(
        gmail_attributes.merge(
          last_inbound_attempted_at: 2.hours.ago,
          last_inbound_synced_at: 1.hour.ago,
          last_inbound_error: "old error"
        )
      )

    pending_receipt = connection.email_message_receipts.create!(
      account: connection.account,
      provider_message_id: "old-pending",
      discovered_at: Time.current
    )
    processing_receipt = connection.email_message_receipts.create!(
      account: connection.account,
      provider_message_id: "old-processing",
      discovered_at: Time.current
    )
    processing_receipt.claim!(job_id: "old-worker")

    connection.connect_gmail!(
      email: "replacement@example.com",
      name: "Replacement Billing",
      provider_account_id: "google-account-999",
      history_id: "900",
      access_token: "replacement-access",
      refresh_token: "replacement-refresh",
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )

    assert_equal "google-account-999", connection.provider_account_id
    assert_equal "900", connection.inbound_cursor
    assert_nil connection.last_inbound_attempted_at
    assert_nil connection.last_inbound_synced_at
    assert_nil connection.last_inbound_error
    [ pending_receipt, processing_receipt ].each do |receipt|
      assert_predicate receipt.reload, :status_ignored?
      assert_equal "mailbox_replaced", receipt.metadata.fetch("reason")
      assert_nil receipt.processing_job_id
    end
  end

  test "disconnect clears identity credentials and inbound state" do
    connection = Account.create!(name: "Disconnect state account")
      .create_email_connection!(
        gmail_attributes.merge(
          last_inbound_attempted_at: 2.hours.ago,
          last_inbound_synced_at: 1.hour.ago,
          last_inbound_error: "old error"
        )
      )

    previous_generation = connection.credential_generation
    connection.disconnect!

    assert_predicate connection, :disconnected?
    assert_nil connection.provider_account_id
    assert_nil connection.access_token
    assert_nil connection.refresh_token
    assert_nil connection.inbound_cursor
    assert_nil connection.inbound_enabled_at
    assert_nil connection.last_inbound_attempted_at
    assert_nil connection.last_inbound_synced_at
    assert_nil connection.last_inbound_error
    assert_equal previous_generation + 1, connection.credential_generation
  end

  test "does not reuse a refresh token for a different Google account" do
    connection = Account.create!(name: "Changed Gmail Account")
      .create_email_connection!(gmail_attributes)

    assert_raises ActiveRecord::RecordInvalid do
      connection.connect_gmail!(
        email: "different@example.com",
        name: "Different User",
        provider_account_id: "different-google-account",
        history_id: "300",
        access_token: "different-access-token",
        refresh_token: nil,
        expires_at: 1.hour.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
    end

    assert_equal "billing@example.com", connection.reload.connected_email
    assert_equal "refresh-token", connection.refresh_token
  end

  private
    def gmail_attributes
      {
        provider: :gmail,
        provider_account_id: "google-account-123",
        connected_email: "billing@example.com",
        provider_display_name: "Billing Team",
        access_token: "access-token",
        refresh_token: "refresh-token",
        token_expires_at: 1.hour.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
        inbound_cursor: "100",
        status: :active
      }
    end
end
