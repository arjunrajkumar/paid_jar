require "test_helper"

class EmailConnection::Gmail::MailboxTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "pages Gmail history using only messageAdded" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    first = Google::Apis::GmailV1::ListHistoryResponse.new(
      history_id: "101",
      next_page_token: "next"
    )
    last = Google::Apis::GmailV1::ListHistoryResponse.new(history_id: "102")
    service.expects(:authorization=).twice.with("gmail-access-token")
    service.expects(:list_user_histories).with(
      "me",
      start_history_id: "100",
      history_types: [ "messageAdded" ],
      page_token: nil
    ).returns(first)
    service.expects(:list_user_histories).with(
      "me",
      start_history_id: "100",
      history_types: [ "messageAdded" ],
      page_token: "next"
    ).returns(last)

    pages = EmailConnection::Gmail::Mailbox.new(connection:, service:)
      .each_history_page(start_history_id: "100")
      .to_a

    assert_equal [ first, last ], pages
  end

  test "lists a bounded mailbox window including spam and trash" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    response = Google::Apis::GmailV1::ListMessagesResponse.new(
      messages: [ Google::Apis::GmailV1::Message.new(id: "gmail-1") ]
    )
    since = Time.zone.at(1_700_000_000)
    service.expects(:authorization=).with("gmail-access-token")
    service.expects(:list_user_messages).with(
      "me",
      include_spam_trash: true,
      q: "after:1700000000",
      page_token: nil
    ).returns(response)

    messages = EmailConnection::Gmail::Mailbox.new(connection:, service:)
      .each_message_since(time: since)
      .to_a

    assert_equal [ "gmail-1" ], messages.map(&:id)
  end

  test "requests full messages without fetching attachments" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    response = Google::Apis::GmailV1::Message.new(id: "gmail-1")
    service.expects(:authorization=).with("gmail-access-token")
    service.expects(:get_user_message).with("me", "gmail-1", format: "full").returns(response)
    service.expects(:get_user_message_attachment).never

    result = EmailConnection::Gmail::Mailbox.new(connection:, service:).message(id: "gmail-1")

    assert_equal response, result
  end

  test "does not load credentials or fetch after the pinned Gmail identity changes" do
    connection = email_connections(:paid_jar_gmail)
    provider_account_id = connection.provider_account_id
    service = mock
    mailbox = EmailConnection::Gmail::Mailbox.new(connection:, provider_account_id:, service:)
    connection.update!(provider_account_id: "replacement-google-account")
    service.expects(:authorization=).never
    service.expects(:get_user_message).never

    assert_raises EmailConnection::Errors::CredentialChanged do
      mailbox.message(id: "old-mailbox-message")
    end
  end

  test "does not fetch after the same Gmail identity is reauthorized" do
    connection = email_connections(:paid_jar_gmail)
    mailbox = EmailConnection::Gmail::Mailbox.new(connection:, service: mock)

    connection.connect_gmail!(
      email: connection.connected_email,
      name: connection.provider_display_name,
      provider_account_id: connection.provider_account_id,
      history_id: "999",
      access_token: "reauthorized-access",
      refresh_token: "reauthorized-refresh",
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )

    assert_raises EmailConnection::Errors::CredentialChanged do
      mailbox.message(id: "old-credential-message")
    end
  end

  test "translates history and message 404 responses separately" do
    connection = email_connections(:paid_jar_gmail)
    history_service = mock
    history_service.stubs(:authorization=)
    history_service.stubs(:list_user_histories).raises(gmail_client_error(status: 404))
    message_service = mock
    message_service.stubs(:authorization=)
    message_service.stubs(:get_user_message).raises(gmail_client_error(status: 404))

    assert_raises EmailConnection::Errors::HistoryExpired do
      EmailConnection::Gmail::Mailbox.new(connection:, service: history_service)
        .each_history_page(start_history_id: "old").to_a
    end
    assert_raises EmailConnection::Errors::MessageNotFound do
      EmailConnection::Gmail::Mailbox.new(connection:, service: message_service).message(id: "deleted")
    end
  end

  test "forces one refresh after a Gmail 401" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    response = Google::Apis::GmailV1::Profile.new(email_address: connection.connected_email, history_id: "101")
    service.stubs(:authorization=)
    service.expects(:get_user_profile)
      .twice
      .raises(Google::Apis::AuthorizationError.new("expired"))
      .then
      .returns(response)
    expected_credentials = {
      provider_account_id: connection.provider_account_id,
      credential_generation: connection.credential_generation
    }
    connection.expects(:refresh_gmail_access_token_if_needed!)
      .with(**expected_credentials)
      .returns("old-token")
      .twice
    connection.expects(:refresh_gmail_access_token_if_needed!)
      .with(force: true, **expected_credentials)
      .returns("new-token")

    result = EmailConnection::Gmail::Mailbox.new(connection:, service:).profile

    assert_equal "101", result.history_id
    assert_predicate connection.reload, :active?
  end

  test "translates temporary OAuth refresh failures into provider failures" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.expects(:authorization=).never
    service.expects(:get_user_profile).never
    connection.expects(:refresh_gmail_access_token_if_needed!)
      .with(
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation
      )
      .raises(EmailConnection::Errors::TemporaryDeliveryError, "private OAuth failure")

    error = assert_raises EmailConnection::Errors::TemporaryProviderError do
      EmailConnection::Gmail::Mailbox.new(connection:, service:).profile
    end

    assert_equal "gmail_temporarily_unavailable", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, "private OAuth failure"
    assert_predicate connection.reload, :active?
  end

  test "translates a temporary forced refresh failure after a Gmail 401" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.expects(:authorization=).with("gmail-access-token")
    service.expects(:get_user_profile)
      .raises(Google::Apis::AuthorizationError.new("expired"))
    expected_credentials = {
      provider_account_id: connection.provider_account_id,
      credential_generation: connection.credential_generation
    }
    connection.expects(:refresh_gmail_access_token_if_needed!)
      .with(**expected_credentials)
      .returns("gmail-access-token")
    connection.expects(:refresh_gmail_access_token_if_needed!)
      .with(force: true, **expected_credentials)
      .raises(EmailConnection::Errors::TemporaryDeliveryError, "private OAuth failure")

    error = assert_raises EmailConnection::Errors::TemporaryProviderError do
      EmailConnection::Gmail::Mailbox.new(connection:, service:).profile
    end

    assert_equal "gmail_temporarily_unavailable", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, "private OAuth failure"
    assert_predicate connection.reload, :active?
  end

  test "translates permanent OAuth failures into permanent provider failures" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.expects(:authorization=).never
    service.expects(:get_user_profile).never
    connection.expects(:refresh_gmail_access_token_if_needed!)
      .with(
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation
      )
      .raises(EmailConnection::Errors::PermanentDeliveryError, "private OAuth failure")

    error = assert_raises EmailConnection::Errors::PermanentProviderError do
      EmailConnection::Gmail::Mailbox.new(connection:, service:).profile
    end

    assert_equal "gmail_request_rejected", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, "private OAuth failure"
    assert_predicate connection.reload, :active?
  end

  test "translates a disabled Gmail API without leaking provider details" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:get_user_profile)
      .raises(Google::Apis::ProjectNotLinkedError.new("private project details"))

    error = assert_raises EmailConnection::Errors::PermanentProviderError do
      EmailConnection::Gmail::Mailbox.new(connection:, service:).profile
    end

    assert_equal "gmail_request_rejected", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, "private project details"
    assert_predicate connection.reload, :active?
  end

  test "recognizes a modern Gmail permission error" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:get_user_profile).raises(
      gmail_client_error(
        status: 403,
        reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
        error_status: "PERMISSION_DENIED"
      )
    )

    error = assert_raises EmailConnection::Errors::AuthorizationError do
      EmailConnection::Gmail::Mailbox.new(connection:, service:).profile
    end

    assert_equal "gmail_authorization_failed", error.message
    assert_nil error.cause
    assert_predicate connection.reload, :errored?
    assert_equal "gmail_authentication_failed", connection.last_error
  end

  test "retries inbound synchronization after 429 and 5xx OAuth refresh responses" do
    connection = email_connections(:paid_jar_gmail)
    starting_cursor = connection.inbound_cursor
    starting_synced_at = connection.last_inbound_synced_at
    token_uri = EmailConnection::Gmail::Configuration.new.token_uri.to_s

    [ 429, 503 ].each do |status|
      connection.update!(token_expires_at: 1.minute.ago, last_inbound_error: nil)
      stub_request(:post, token_uri).to_return(
        status:,
        body: { error: "temporarily_unavailable" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      assert_enqueued_with(
        job: EmailConnections::SyncInboundJob,
        args: [
          connection.id,
          connection.provider_account_id,
          connection.credential_generation
        ]
      ) do
        EmailConnections::SyncInboundJob.perform_now(
          connection.id,
          connection.provider_account_id,
          connection.credential_generation
        )
      end

      assert_predicate connection.reload, :active?, "HTTP #{status} marked the connection errored"
      assert_equal starting_cursor, connection.inbound_cursor, "HTTP #{status} advanced the cursor"
      assert_equal starting_synced_at, connection.last_inbound_synced_at,
        "HTTP #{status} changed the successful-sync timestamp"
      assert_equal EmailConnection::Errors::TemporaryProviderError.name, connection.last_inbound_error
      clear_enqueued_jobs
      connection.update_columns(inbound_sync_job_id: nil, inbound_sync_enqueued_at: nil)
    end
  end

  private
    def gmail_client_error(status:, reason: nil, error_status: nil)
      errors = reason && error_status.nil? ? [ { reason: } ] : []
      details = reason && error_status ? [ { reason: } ] : []
      Google::Apis::ClientError.new(
        "Gmail rejected the request",
        status_code: status,
        body: {
          error: {
            errors:,
            details:,
            status: error_status
          }.compact
        }.to_json
      )
    end
end
