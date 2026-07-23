require "test_helper"

class EmailConnection::Gmail::DeliveryTest < ActiveSupport::TestCase
  test "sends the rendered multipart reminder through Gmail with the account sender" do
    invoice = invoices(:xero_invoice)
    invoice.provider_data["online_invoice_url"] = "https://example.com/invoices/INV-001"
    connection = email_connections(:paid_jar_gmail)
    invoice.account.update!(invoice_reminder_from_name: "Accounts Team")
    service = mock
    response = Struct.new(:id, :thread_id).new("gmail-message-123", "gmail-thread-456")
    captured_message = nil
    service.expects(:authorization=).with("gmail-access-token")
    service.expects(:send_user_message).with do |user_id, message|
      captured_message = Mail.read_from_string(message.raw)
      user_id == "me"
    end.returns(response)
    mail_message = InvoiceReminderMailer.reminder(
      invoice,
      invoice_schedules(:normal_pre_due_7)
    ).message

    result = EmailConnection::Gmail::Delivery.new(
      account: invoice.account,
      connection:,
      provider_account_id: connection.provider_account_id,
      credential_generation: connection.credential_generation,
      service:
    ).deliver(mail_message)

    assert_equal "gmail-message-123", result.provider_message_id
    assert_equal "gmail-thread-456", result.provider_thread_id
    assert_equal [ "billing@paymentreminder.example" ], captured_message.from
    assert_equal [ "Accounts Team" ], captured_message[:from].display_names
    assert_equal [ "customer@example.com" ], captured_message.to
    assert_equal "Upcoming Payment Due: Invoice INV-001", captured_message.subject
    assert_match "friendly reminder", captured_message.text_part.body.to_s
    assert_match "https://example.com/invoices/INV-001", captured_message.text_part.body.to_s
    assert_match "https://example.com/invoices/INV-001", captured_message.html_part.body.to_s
  end

  test "refuses to deliver through another account's Gmail connection" do
    other_account = Account.create!(name: "Other Delivery Account")
    connection = email_connections(:paid_jar_gmail)
    connection.expects(:refresh_gmail_access_token_if_needed!).never
    mail_message = InvoiceReminderMailer.reminder(
      invoices(:xero_invoice),
      invoice_schedules(:normal_pre_due_7)
    ).message

    error = assert_raises EmailConnection::Errors::PermanentDeliveryError do
      EmailConnection::Gmail::Delivery.new(
        account: other_account,
        connection:,
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation,
        service: mock
      ).deliver(mail_message)
    end

    assert_match "not active for this account", error.message
  end

  test "marks the connection errored when Gmail revokes authorization" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:send_user_message).raises(Google::Apis::AuthorizationError.new("revoked"))
    expected_credentials = {
      provider_account_id: connection.provider_account_id,
      credential_generation: connection.credential_generation
    }
    connection.expects(:refresh_gmail_access_token_if_needed!)
      .with(**expected_credentials)
      .returns(connection.access_token)
    connection.expects(:refresh_gmail_access_token_if_needed!)
      .with(force: true, **expected_credentials)
      .returns(connection.access_token)

    error = assert_raises EmailConnection::Errors::AuthenticationError do
      EmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end

    assert_predicate connection.reload, :errored?
    assert_equal "gmail_authentication_failed", connection.last_error
    assert_equal "Gmail authentication failed.", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, "revoked"
  end

  test "force refreshes once after Gmail rejects a valid-looking access token" do
    connection = email_connections(:paid_jar_gmail)
    old_access_token = connection.access_token
    EmailConnection::Gmail::OauthClient.any_instance.expects(:refresh_token)
      .with(refresh_token: connection.refresh_token)
      .once
      .returns(
        "access_token" => "refreshed-access-token",
        "expires_in" => 3600
      )
    authorizations = []
    send_attempts = 0
    service = Object.new
    service.define_singleton_method(:authorization=) { |token| authorizations << token }
    service.define_singleton_method(:send_user_message) do |*, **|
      send_attempts += 1
      raise Google::Apis::AuthorizationError, "expired" if send_attempts == 1

      Struct.new(:id, :thread_id).new("gmail-after-refresh", "thread-after-refresh")
    end

    result = EmailConnection::Gmail::Delivery.new(
      account: connection.account,
      connection:,
      provider_account_id: connection.provider_account_id,
      credential_generation: connection.credential_generation,
      service:
    ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))

    assert_equal "gmail-after-refresh", result.provider_message_id
    assert_equal [ old_access_token, "refreshed-access-token" ], authorizations
    assert_predicate connection.reload, :active?
  end

  test "does not mark a newer same-generation access token errored for an old 401" do
    connection = email_connections(:paid_jar_gmail)
    EmailConnection::Gmail::OauthClient.any_instance.expects(:refresh_token)
      .with(refresh_token: connection.refresh_token)
      .once
      .returns(
        "access_token" => "forced-access-token",
        "expires_in" => 3600
      )
    service = Object.new
    service.define_singleton_method(:authorization=) { |_| }
    service.define_singleton_method(:send_user_message) do |*, **|
      raise Google::Apis::AuthorizationError, "stale authorization failure"
    end
    original_mark_errored = connection.method(:mark_errored!)
    connection.define_singleton_method(:mark_errored!) do |error, **attributes|
      update!(access_token: "winning-access-token", token_expires_at: 1.hour.from_now)
      original_mark_errored.call(error, **attributes)
    end

    error = assert_raises EmailConnection::Errors::TemporaryDeliveryError do
      EmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end

    assert_equal "Gmail credentials changed; retry delivery.", error.message
    assert_nil error.cause
    assert_predicate connection.reload, :active?
    assert_equal "winning-access-token", connection.access_token
  end

  test "classifies Gmail rate limits as temporary" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:send_user_message).raises(gmail_client_error("userRateLimitExceeded"))

    assert_raises EmailConnection::Errors::TemporaryDeliveryError do
      EmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end

    assert_predicate connection.reload, :active?
  end

  test "translates a disabled Gmail API into a permanent delivery failure" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:send_user_message)
      .raises(Google::Apis::ProjectNotLinkedError.new("private project details"))

    error = assert_raises EmailConnection::Errors::PermanentDeliveryError do
      EmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end

    assert_equal "Gmail rejected the request.", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, "private project details"
    assert_predicate connection.reload, :active?
  end

  test "recognizes a modern Gmail permission error and marks the connection errored" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:send_user_message).raises(
      gmail_client_error(
        "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
        status: "PERMISSION_DENIED"
      )
    )

    assert_raises EmailConnection::Errors::AuthenticationError do
      EmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end

    assert_predicate connection.reload, :errored?
    assert_equal "gmail_authentication_failed", connection.last_error
  end

  test "classifies a lost Gmail response as ambiguous rather than safely retryable" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:send_user_message).raises(Google::Apis::TransmissionError.new("connection lost"))

    assert_raises EmailConnection::Errors::AmbiguousDeliveryError do
      EmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        provider_account_id: connection.provider_account_id,
        credential_generation: connection.credential_generation,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end

    assert_predicate connection.reload, :active?
  end

  test "does not call Gmail after the reserved credential generation is replaced" do
    connection = email_connections(:paid_jar_gmail)
    expected_provider_account_id = connection.provider_account_id
    expected_generation = connection.credential_generation
    service = mock
    service.expects(:authorization=).never
    service.expects(:send_user_message).never

    connection.connect_gmail!(
      email: connection.connected_email,
      name: connection.provider_display_name,
      provider_account_id: expected_provider_account_id,
      history_id: "999",
      access_token: "reauthorized-access",
      refresh_token: "reauthorized-refresh",
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )

    assert_raises EmailConnection::Errors::CredentialChanged do
      EmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        provider_account_id: expected_provider_account_id,
        credential_generation: expected_generation,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end
  end

  test "sends a plain-text reply in the requested Gmail thread with RFC reply headers" do
    connection = email_connections(:paid_jar_gmail)
    service = mock
    captured_request = nil
    service.expects(:authorization=).with("gmail-access-token")
    service.expects(:send_user_message).with do |user_id, request|
      captured_request = request
      user_id == "me"
    end.returns(
      Struct.new(:id, :thread_id).new("threaded-reply-id", "requested-thread")
    )
    mail_message = Mail.new(
      to: "customer@example.com",
      subject: "Re: Invoice question",
      body: "Thanks for your message."
    )
    mail_message["In-Reply-To"] = "<customer-message@example.com>"
    mail_message["References"] = "<older@example.com> <customer-message@example.com>"

    result = EmailConnection::Gmail::Delivery.new(
      account: connection.account,
      connection:,
      provider_account_id: connection.provider_account_id,
      credential_generation: connection.credential_generation,
      requested_provider_thread_id: "requested-thread",
      service:
    ).deliver(mail_message)

    delivered_mail = Mail.read_from_string(captured_request.raw)
    assert_equal "requested-thread", captured_request.thread_id
    assert_equal "<customer-message@example.com>", delivered_mail["In-Reply-To"].value
    assert_equal "<older@example.com> <customer-message@example.com>",
      delivered_mail["References"].value
    assert_equal "threaded-reply-id", result.provider_message_id
  end

  private
    def gmail_client_error(reason, status: nil)
      errors = status ? [] : [ { reason: } ]
      details = status ? [ { reason: } ] : []
      Google::Apis::ClientError.new(
        "Gmail rejected the request",
        status_code: 403,
        body: {
          error: {
            errors:,
            details:,
            status:
          }.compact
        }.to_json
      )
    end
end
