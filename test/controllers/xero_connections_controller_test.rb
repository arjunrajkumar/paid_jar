require "test_helper"

class XeroConnectionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "connect requires a PaymentReminder session" do
    get new_xero_connection_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "connect requests the full Xero invoice scopes with signed state and an OIDC nonce" do
    account = sign_up_and_complete
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: account.slug)
    end

    assert_redirected_to FakeXeroClient::AUTHORIZATION_URL
    assert fake_client.authorization_options.fetch(:state).present?
    assert fake_client.authorization_options.fetch(:nonce).present?
    assert_equal InvoiceSources::Xero::Configuration.new.redirect_uri,
      fake_client.authorization_options.fetch(:redirect_uri)

    scopes = requested_scopes(fake_client)
    assert_includes scopes, "openid"
    assert_includes scopes, "profile"
    assert_includes scopes, "email"
    assert_includes scopes, "accounting.invoices.read"
    assert_includes scopes, "offline_access"
    assert_includes scopes, "accounting.contacts.read"
  end

  test "connect requires an account-scoped request for an active membership" do
    sign_up_and_complete
    inaccessible_account = Account.create!(name: "Inaccessible account")
    InvoiceSources::Xero::OauthClient.expects(:new).never

    get new_xero_connection_url(script_name: inaccessible_account.slug)

    assert_redirected_to root_url(script_name: nil)
    assert_equal "Choose a PaymentReminder account you can access.", flash[:alert]
  end

  test "connect requires an account administrator" do
    account = sign_up_and_complete(email_address: "member-xero-connect@example.com")
    account.users.owner.sole.update!(role: :member)
    InvoiceSources::Xero::OauthClient.expects(:new).never

    get new_xero_connection_url(script_name: account.slug)

    assert_redirected_to root_url(script_name: nil)
    assert_equal "You need to be an account owner or administrator to do that.", flash[:alert]
  end

  test "connect redirects to scoped Settings when credentials are missing" do
    account = sign_up_and_complete
    InvoiceSources::Xero::Configuration.any_instance.stubs(:configured?).returns(false)

    get new_xero_connection_url(script_name: account.slug)

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Xero credentials are not configured.", flash[:alert]
  end

  test "verified callback links the Xero identity connects the tenant and queues a refresh" do
    account = sign_up_and_complete
    identity = account.users.owner.sole.identity
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: account.slug)
      stub_completed_authorization(
        authorization_result,
        nonce: fake_client.authorization_options.fetch(:nonce)
      )

      assert_difference -> { ExternalIdentity.count }, 1 do
        assert_difference -> { account.invoice_sources.xero.count }, 1 do
          assert_enqueued_with(job: InvoiceSources::RefreshJob) do
            get xero_callback_url, params: {
              code: "auth-code",
              state: fake_client.state
            }
          end
        end
      end
    end

    source = account.invoice_sources.xero.sole
    external_identity = identity.external_identities.xero.sole

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Xero connected. Your invoices are syncing now.", flash[:notice]
    assert_equal "xero-user-connection", external_identity.subject
    assert_equal "verified-owner@example.com", external_identity.email_address
    assert_predicate source, :connected?
    assert_equal "tenant-connection", source.external_account_id
    assert_equal "Connection Ltd", source.external_account_name
    assert_equal "connection-connection", source.provider_data.fetch("connection_id")
    assert_equal "auth-event-connection",
      source.provider_data.fetch("authentication_event_id")
  end

  test "callback connects only the non-first account that initiated authorization" do
    first_account = sign_up_and_complete(email_address: "multi-account-owner@example.com")
    identity = first_account.users.owner.sole.identity
    origin_account = add_account(identity:, name: "OAuth origin account")
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: origin_account.slug)
      stub_completed_authorization(
        authorization_result(
          tenant_id: "tenant-multi-account",
          tenant_name: "Multi Account Ltd",
          connection_id: "connection-multi-account"
        ),
        nonce: fake_client.authorization_options.fetch(:nonce)
      )

      get xero_callback_url, params: {
        code: "auth-code",
        state: fake_client.state
      }
    end

    assert_empty first_account.invoice_sources.xero
    assert_equal "tenant-multi-account",
      origin_account.invoice_sources.xero.sole.external_account_id
    assert_redirected_to account_settings_url(script_name: origin_account.slug)
  end

  test "platform administrator impersonating a member can connect that exact account" do
    platform_account = sign_up_and_complete(email_address: "platform-xero@example.com")
    target_account = add_account(
      identity: Identity.create!(email_address: "target-xero-owner@example.com"),
      name: "Platform Xero Target"
    )
    target_member = target_account.users.create!(
      name: "Target Member",
      role: :member,
      identity: Identity.create!(email_address: "target-xero-member@example.com")
    )
    PlatformAdminAccess.stubs(:allowed?).returns(true)
    post impersonate_madmin_user_url(target_member, script_name: nil)
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: target_account.slug)
      stub_completed_authorization(
        authorization_result(
          tenant_id: "tenant-platform-xero",
          tenant_name: "Platform Xero Ltd",
          connection_id: "connection-platform-xero"
        ),
        nonce: fake_client.authorization_options.fetch(:nonce)
      )

      get xero_callback_url(script_name: nil), params: {
        code: "auth-code",
        state: fake_client.state
      }
    end

    assert_empty platform_account.invoice_sources.xero
    assert_redirected_to account_settings_url(script_name: target_account.slug)
    assert_nil flash[:alert]
    assert_equal "tenant-platform-xero", target_account.invoice_sources.xero.sole.external_account_id
  end

  test "an account-scoped callback for another account is rejected before token exchange" do
    first_account = sign_up_and_complete(email_address: "scoped-callback-owner@example.com")
    identity = first_account.users.owner.sole.identity
    origin_account = add_account(identity:, name: "Callback origin account")
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: origin_account.slug)
      Xero::Authorization.expects(:new).never

      get xero_callback_url(script_name: first_account.slug), params: {
        code: "auth-code",
        state: fake_client.state
      }
    end

    assert_empty first_account.invoice_sources.xero
    assert_empty origin_account.invoice_sources.xero
    assert_empty identity.external_identities.xero
    assert_redirected_to account_settings_url(script_name: origin_account.slug)
    assert_equal "Xero connection could not be verified.", flash[:alert]
  end

  test "callback rejects a membership deactivated after authorization started before token exchange" do
    first_account = sign_up_and_complete(email_address: "inactive-origin-owner@example.com")
    identity = first_account.users.owner.sole.identity
    origin_account = add_account(identity:, name: "Inactive origin account")
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: origin_account.slug)
      origin_account.users.owner.sole.deactivate
      Xero::Authorization.expects(:new).never

      get xero_callback_url, params: {
        code: "auth-code",
        state: fake_client.state
      }
    end

    assert_empty first_account.invoice_sources.xero
    assert_empty origin_account.invoice_sources.xero
    assert_empty identity.external_identities.xero
    assert_redirected_to root_url(script_name: nil)
  end

  test "callback rejects an administrator demoted after authorization started" do
    account = sign_up_and_complete(email_address: "demoted-xero-owner@example.com")
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: account.slug)
      account.users.owner.sole.update!(role: :member)
      Xero::Authorization.expects(:new).never

      get xero_callback_url, params: {
        code: "auth-code",
        state: fake_client.state
      }
    end

    assert_empty account.invoice_sources.xero
    assert_redirected_to root_url(script_name: account.slug)
  end

  test "invalid state consumes the account-bound attempt before token exchange" do
    account = sign_up_and_complete(email_address: "invalid-state-owner@example.com")
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: account.slug)
      Xero::Authorization.expects(:new).never

      get xero_callback_url, params: { code: "auth-code", state: "wrong-state" }

      assert_redirected_to account_settings_url(script_name: account.slug)

      get xero_callback_url, params: { code: "auth-code", state: fake_client.state }
    end

    assert_empty account.invoice_sources.xero
    assert_empty account.users.owner.sole.identity.external_identities.xero
    assert_redirected_to root_url
  end

  test "provider denial consumes the account-bound attempt without token exchange" do
    account = sign_up_and_complete(email_address: "denied-xero-owner@example.com")
    fake_client = FakeXeroClient.new

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: account.slug)
      Xero::Authorization.expects(:new).never

      get xero_callback_url, params: {
        error: "access_denied",
        state: fake_client.state
      }
    end

    assert_empty account.invoice_sources.xero
    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Xero access was not approved.", flash[:alert]
  end

  test "verified authorization failures do not create local credentials" do
    account = sign_up_and_complete(email_address: "authorization-error-owner@example.com")
    fake_client = FakeXeroClient.new
    authorization = mock("failed Xero authorization")
    authorization.expects(:complete!).once.raises(
      Xero::Authorization::Error,
      "Xero returned invalid credentials."
    )

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: account.slug)
      Xero::Authorization.stubs(:new).returns(authorization)

      get xero_callback_url, params: {
        code: "auth-code",
        state: fake_client.state
      }
    end

    assert_empty account.invoice_sources.xero
    assert_empty account.users.owner.sole.identity.external_identities.xero
    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Xero returned invalid credentials.", flash[:alert]
  end

  test "an enqueue failure does not undo a verified connection" do
    account = sign_up_and_complete(email_address: "enqueue-error-owner@example.com")
    fake_client = FakeXeroClient.new
    enqueue_error = ActiveJob::EnqueueError.new("queue unavailable")

    with_xero_client(fake_client) do
      get new_xero_connection_url(script_name: account.slug)
      stub_completed_authorization(
        authorization_result(
          tenant_id: "tenant-enqueue-error",
          connection_id: "connection-enqueue-error"
        ),
        nonce: fake_client.authorization_options.fetch(:nonce)
      )
      InvoiceSources::RefreshJob.stubs(:perform_later).raises(enqueue_error)
      Rails.error.expects(:report).with(enqueue_error, severity: :error)

      get xero_callback_url, params: {
        code: "auth-code",
        state: fake_client.state
      }
    end

    assert_predicate account.invoice_sources.xero.sole, :connected?
    assert_redirected_to account_settings_url(script_name: account.slug)
  end

  test "destroy remotely disconnects an error-state source from the scoped account" do
    account = sign_up_and_complete(email_address: "disconnect-error-state-owner@example.com")
    source = create_xero_source(account, status: :error)
    adapter = mock("Xero adapter")
    adapter.expects(:disconnect!).returns(source)
    InvoiceSources::Xero.expects(:new).with(source).returns(adapter)

    delete xero_connection_url(script_name: account.slug)

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Xero disconnected.", flash[:notice]
  end

  test "destroy reports remote failure and keeps the retry path in scoped Settings" do
    account = sign_up_and_complete(email_address: "disconnect-failure-owner@example.com")
    source = create_xero_source(account)
    error = InvoiceSources::Xero::DisconnectError.new("connection ID missing")
    adapter = mock("Xero adapter")
    adapter.expects(:disconnect!).raises(error)
    InvoiceSources::Xero.expects(:new).with(source).returns(adapter)
    Rails.error.expects(:report).with(error, severity: :warning)

    delete xero_connection_url(script_name: account.slug)

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Xero could not be disconnected. Please try again.", flash[:alert]
  end

  test "destroy never selects another account's Xero source" do
    account = sign_up_and_complete(email_address: "isolated-disconnect-owner@example.com")
    identity = account.users.owner.sole.identity
    other_account = add_account(identity:, name: "Other disconnect account")
    other_source = create_xero_source(
      other_account,
      tenant_id: "tenant-other-disconnect",
      connection_id: "connection-other-disconnect"
    )
    InvoiceSources::Xero.expects(:new).never

    delete xero_connection_url(script_name: account.slug)

    assert_redirected_to new_xero_connection_url(script_name: account.slug)
    assert_equal "Connect Xero first.", flash[:alert]
    assert_predicate other_source.reload, :active?
    assert_equal "disconnect-access-token", other_source.access_token
  end

  private
    def sign_up_and_complete(email_address: "owner-xero@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: } }

      Identity.find_by!(email_address:).accounts.first.tap { clear_enqueued_jobs }
    end

    def add_account(identity:, name:)
      Account.create_with_owner(
        account: { name: },
        owner: { name: "Owner Person", identity: }
      )
    end

    def create_xero_source(
      account,
      status: :active,
      tenant_id: "tenant-controller-disconnect",
      connection_id: "connection-controller-disconnect"
    )
      account.invoice_sources.create!(
        provider: :xero,
        status:,
        external_account_id: tenant_id,
        external_account_name: "Controller Disconnect Ltd",
        access_token: "disconnect-access-token",
        refresh_token: "disconnect-refresh-token",
        expires_at: 30.minutes.from_now,
        provider_data: { connection_id: }
      )
    end

    def authorization_result(
      subject: "xero-user-connection",
      tenant_id: "tenant-connection",
      tenant_name: "Connection Ltd",
      connection_id: "connection-connection"
    )
      Xero::Authorization::Result.new(
        identity: Xero::VerifiedIdentity.new(
          subject:,
          email: "verified-owner@example.com",
          given_name: "Verified",
          family_name: "Owner"
        ),
        token_set: {
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
        },
        connections: [
          {
            "id" => connection_id,
            "authEventId" => "auth-event-connection",
            "tenantId" => tenant_id,
            "tenantType" => "ORGANISATION",
            "tenantName" => tenant_name
          }
        ],
        authentication_event_id: "auth-event-connection"
      )
    end

    def stub_completed_authorization(result, nonce:)
      authorization = mock("completed Xero authorization")
      authorization.expects(:complete!).with(
        code: "auth-code",
        redirect_uri: InvoiceSources::Xero::Configuration.new.redirect_uri,
        nonce:,
        include_connections: true
      ).returns(result)
      Xero::Authorization.stubs(:new).returns(authorization)
    end

    def with_xero_client(fake_client)
      InvoiceSources::Xero::Configuration.any_instance.stubs(:configured?).returns(true)
      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)
      yield
    end

    def requested_scopes(fake_client)
      value = fake_client.authorization_options[:scopes]
      value.respond_to?(:to_ary) ? value.to_ary : value.to_s.split
    end

    class FakeXeroClient
      AUTHORIZATION_URL = "https://login.xero.com/identity/connect/authorize?fake=connection"

      attr_reader :authorization_options

      def authorization_url(**options)
        @authorization_options = options
        AUTHORIZATION_URL
      end

      def state
        authorization_options.fetch(:state)
      end
    end
end
