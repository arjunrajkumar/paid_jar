require "test_helper"

class GmailConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    EmailConnection::Gmail::Configuration.any_instance.stubs(:configured?).returns(true)
  end

  test "callback connects Gmail only to the initiating account" do
    account = sign_up_and_complete
    other_account = Account.create!(name: "Other Account")
    client = FakeGmailOauthClient.new
    EmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: nil), params: { code: "auth-code", state: client.state }

    connection = account.reload.email_connection
    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_predicate connection, :active?
    assert_equal "billing@example.com", connection.connected_email
    assert_nil other_account.reload.email_connection
  end

  test "unscoped callback restores the initiating account for a multi-account administrator" do
    first_account = sign_up_and_complete(email_address: "multi-account-admin@example.com")
    identity = first_account.users.owner.sole.identity
    second_account = Account.create!(name: "Second Admin Account")
    second_account.users.create!(
      identity:,
      name: "Multi Account Admin",
      role: :owner
    )
    client = FakeGmailOauthClient.new
    EmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: second_account.slug)
    get gmail_callback_url(script_name: nil), params: { code: "auth-code", state: client.state }

    assert_redirected_to account_settings_url(script_name: second_account.slug)
    assert_nil first_account.reload.email_connection
    assert_predicate second_account.reload.email_connection, :active?
  end

  test "callback cannot connect Gmail through another account's state" do
    account = sign_up_and_complete(email_address: "owner-state@example.com")
    other_account = Account.create!(name: "Other State Account")
    client = FakeGmailOauthClient.new
    EmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: other_account.slug), params: { code: "auth-code", state: client.state }

    assert_nil account.reload.email_connection
    assert_nil other_account.reload.email_connection
    assert_equal "Gmail connection could not be verified.", flash[:alert]
  end

  test "reconnection updates tokens and preserves the existing refresh token" do
    account = sign_up_and_complete(email_address: "owner-reconnect@example.com")
    connection = account.create_email_connection!(
      provider: :gmail,
      provider_account_id: "google-account-123",
      connected_email: "billing@example.com",
      access_token: "old-access",
      refresh_token: "old-refresh",
      token_expires_at: 1.minute.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
      inbound_cursor: "100",
      status: :active
    )
    client = FakeGmailOauthClient.new(refresh_token: nil)
    EmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: account.slug), params: { code: "auth-code", state: client.state }

    assert_equal "access-token", connection.reload.access_token
    assert_equal "old-refresh", connection.refresh_token
    assert_equal "100", connection.inbound_cursor
  end

  test "a different Google identity resets the mailbox baseline" do
    account = sign_up_and_complete(email_address: "owner-replace@example.com")
    connection = connect_gmail(account)
    connection.update!(last_inbound_synced_at: 1.day.ago)
    client = FakeGmailOauthClient.new(
      provider_account_id: "replacement-google-account",
      email: "replacement@example.com",
      history_id: "900"
    )
    EmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: account.slug), params: { code: "auth-code", state: client.state }

    connection.reload
    assert_equal "replacement-google-account", connection.provider_account_id
    assert_equal "replacement@example.com", connection.connected_email
    assert_equal "900", connection.inbound_cursor
    assert_nil connection.last_inbound_synced_at
  end

  test "callback rejects a grant without Gmail readonly" do
    account = sign_up_and_complete(email_address: "owner-scope@example.com")
    scopes = EmailConnection::Gmailable::REQUIRED_SCOPES - [ EmailConnection::Gmailable::READ_SCOPE ]
    client = FakeGmailOauthClient.new(scopes:)
    EmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: account.slug), params: { code: "auth-code", state: client.state }

    assert_nil account.reload.email_connection
    assert_includes flash[:alert], "did not grant all required Gmail permissions"
  end

  test "callback remains successful when the initial inbound sync cannot enqueue" do
    account = sign_up_and_complete(email_address: "owner-enqueue-failure@example.com")
    client = FakeGmailOauthClient.new
    EmailConnection::Gmail::OauthClient.stubs(:new).returns(client)
    ActiveJob::Base.queue_adapter.stubs(:enqueue).raises(RuntimeError, "queue unavailable")
    Rails.error.expects(:report).with(instance_of(RuntimeError), severity: :error)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: nil), params: { code: "auth-code", state: client.state }

    connection = account.reload.email_connection
    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Gmail connected.", flash[:notice]
    assert_predicate connection, :active?
    assert_nil connection.inbound_sync_job_id
    assert_nil connection.inbound_sync_enqueued_at
  end

  test "disconnect disables reminders and removes usable credentials" do
    account = sign_up_and_complete(email_address: "owner-disconnect@example.com")
    connection = connect_gmail(account)
    account.update!(automatic_invoice_reminders_enabled: true)

    delete gmail_connection_url(script_name: account.slug)

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_not_predicate account.reload, :automatic_invoice_reminders_enabled?
    assert_predicate connection.reload, :disconnected?
    assert_nil connection.access_token
    assert_nil connection.refresh_token
  end

  test "test action sends through Gmail to the current identity" do
    account = sign_up_and_complete(email_address: "owner-test-email@example.com")
    connect_gmail(account)
    delivery = mock
    delivery.expects(:deliver).with do |message|
      message.to == [ "owner-test-email@example.com" ] &&
        message.subject == "PaymentReminder Gmail connection test"
    end.returns("test-message-id")
    EmailConnection::Delivery.stubs(:new).returns(delivery)

    post test_gmail_connection_url(script_name: account.slug)

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Test email sent.", flash[:notice]
  end

  test "members cannot mutate the Gmail connection" do
    account = sign_up_and_complete(email_address: "member-gmail@example.com")
    connection = connect_gmail(account)
    account.users.owner.sole.update!(role: :member)
    EmailConnection::Gmail::OauthClient.expects(:new).never
    EmailConnection::Delivery.expects(:new).never

    get new_gmail_connection_url(script_name: account.slug)
    assert_redirected_to root_url(script_name: nil)

    post test_gmail_connection_url(script_name: account.slug)
    assert_redirected_to root_url(script_name: nil)

    delete gmail_connection_url(script_name: account.slug)
    assert_redirected_to root_url(script_name: nil)
    assert_predicate connection.reload, :active?
  end

  test "callback is rejected when the initiating administrator was demoted" do
    account = sign_up_and_complete(email_address: "demoted-gmail@example.com")
    client = FakeGmailOauthClient.new
    EmailConnection::Gmail::OauthClient.stubs(:new).returns(client)
    get new_gmail_connection_url(script_name: account.slug)
    account.users.owner.sole.update!(role: :member)

    get gmail_callback_url(script_name: account.slug), params: { code: "auth-code", state: client.state }

    assert_redirected_to root_url(script_name: nil)
    assert_nil account.reload.email_connection
  end

  private
    def sign_up_and_complete(email_address: "owner-gmail@example.com")
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address:).accounts.first
    end

    def connect_gmail(account)
      account.build_email_connection.connect_gmail!(
        email: "billing@example.com",
        name: "Billing Team",
        provider_account_id: "google-account-123",
        history_id: "100",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 1.hour.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
    end

    class FakeGmailOauthClient
      AUTHORIZATION_URL = "https://accounts.google.test/authorize"

      attr_reader :state

      def initialize(
        refresh_token: "refresh-token",
        provider_account_id: "google-account-123",
        email: "billing@example.com",
        history_id: "100",
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
        @refresh_token = refresh_token
        @provider_account_id = provider_account_id
        @email = email
        @history_id = history_id
        @scopes = scopes
      end

      def authorization_url(state:, redirect_uri:)
        @state = state
        AUTHORIZATION_URL
      end

      def exchange_code(code:, redirect_uri:)
        raise "unexpected code" unless code == "auth-code"

        {
          "access_token" => "access-token",
          "refresh_token" => @refresh_token,
          "expires_in" => 3600,
          "scope" => @scopes.join(" ")
        }
      end

      def userinfo(access_token:)
        raise "unexpected token" unless access_token == "access-token"

        { "id" => @provider_account_id, "email" => @email, "name" => "Billing Team" }
      end

      def gmail_profile(access_token:)
        raise "unexpected token" unless access_token == "access-token"

        Google::Apis::GmailV1::Profile.new(
          email_address: @email,
          history_id: @history_id
        )
      end
    end
end
