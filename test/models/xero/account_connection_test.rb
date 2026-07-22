require "test_helper"

class Xero::AccountConnectionTest < ActiveSupport::TestCase
  setup do
    @identity = Identity.create!(email_address: "account-connection-owner@example.com")
    @account = Account.create_with_owner(
      account: { name: "Account connection" },
      owner: { name: "Owner Person", identity: @identity }
    )
    @authorization = authorization_result
  end

  test "links the verified identity and connects the sole organization from the current authorization event" do
    stale_connection = organization_connection(
      id: "stale-connection",
      tenant_id: "stale-tenant",
      auth_event_id: "stale-auth-event"
    )
    practice_connection = organization_connection(
      id: "practice-connection",
      tenant_id: "practice-tenant",
      tenant_type: "PRACTICE"
    )
    authorization = @authorization.with(
      connections: [ stale_connection, practice_connection, organization_connection ]
    )

    assert_difference -> { ExternalIdentity.count }, 1 do
      assert_difference -> { InvoiceSource.count }, 1 do
        @result = connect(authorization:)
      end
    end

    assert_equal @identity, @result.external_identity.identity
    assert_equal "xero-user-account-connection", @result.external_identity.subject
    assert_equal "verified-owner@example.com", @result.external_identity.email_address
    assert_equal @account, @result.invoice_source.account
    assert_equal "tenant-account-connection", @result.invoice_source.external_account_id
    assert_equal "connection-account-connection",
      @result.invoice_source.provider_data.fetch("connection_id")
    assert_equal "auth-event-account-connection",
      @result.invoice_source.provider_data.fetch("authentication_event_id")
    assert_predicate @result.invoice_source, :connected?
  end

  test "requires exactly one organization from the current authorization event" do
    second_connection = organization_connection(
      id: "second-connection",
      tenant_id: "second-tenant"
    )
    authorization = @authorization.with(
      connections: [ organization_connection, second_connection ]
    )

    assert_no_connection_changes do
      assert_raises Xero::AccountConnection::ConnectionError do
        connect(authorization:)
      end
    end
  end

  test "rejects an incomplete organization connection" do
    authorization = @authorization.with(
      connections: [ organization_connection.except("id") ]
    )

    assert_no_connection_changes do
      assert_raises Xero::AccountConnection::ConnectionError do
        connect(authorization:)
      end
    end
  end

  test "requires refresh credentials before linking the identity" do
    authorization = @authorization.with(
      token_set: @authorization.token_set.except("refresh_token")
    )

    assert_no_connection_changes do
      assert_raises Xero::AccountConnection::ConnectionError do
        connect(authorization:)
      end
    end
  end

  test "rejects a verified subject linked to another identity" do
    other_identity = Identity.create!(email_address: "other-xero-owner@example.com")
    other_identity.external_identities.create!(
      provider: :xero,
      subject: @authorization.identity.subject
    )

    assert_no_difference -> { @account.invoice_sources.xero.count } do
      assert_raises Xero::AccountConnection::IdentityConflictError do
        connect
      end
    end

    assert_empty @identity.external_identities.xero
  end

  test "rejects linking a different subject to an identity that already has Xero" do
    existing_identity = @identity.external_identities.create!(
      provider: :xero,
      subject: "different-xero-user"
    )

    assert_no_difference -> { ExternalIdentity.count } do
      assert_no_difference -> { @account.invoice_sources.xero.count } do
        assert_raises Xero::AccountConnection::IdentityConflictError do
          connect
        end
      end
    end

    assert_equal "different-xero-user", existing_identity.reload.subject
  end

  test "reuses a matching identity and tenant when reconnecting" do
    external_identity = @identity.external_identities.create!(
      provider: :xero,
      subject: @authorization.identity.subject,
      email_address: "old-email@example.com"
    )
    source = @account.invoice_sources.create!(
      provider: :xero,
      status: :disconnected,
      external_account_id: organization_connection.fetch("tenantId"),
      external_account_name: "Old tenant name"
    )

    assert_no_difference [ -> { ExternalIdentity.count }, -> { InvoiceSource.count } ] do
      @result = connect
    end

    assert_equal external_identity, @result.external_identity
    assert_equal "verified-owner@example.com", external_identity.reload.email_address
    assert_equal source, @result.invoice_source
    assert_predicate source.reload, :connected?
    assert_equal "access-token", source.access_token
  end

  test "rejects switching an account to a different Xero organization" do
    source = @account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "different-tenant",
      external_account_name: "Different tenant",
      access_token: "old-access-token",
      refresh_token: "old-refresh-token"
    )

    assert_no_difference -> { ExternalIdentity.count } do
      assert_raises Xero::AccountConnection::ConnectionError do
        connect
      end
    end

    assert_equal "different-tenant", source.reload.external_account_id
    assert_equal "old-access-token", source.access_token
  end

  test "rejects a Xero organization connected to another account" do
    other_account = Account.create!(name: "Other account")
    other_account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: organization_connection.fetch("tenantId"),
      external_account_name: "Other tenant",
      access_token: "other-access-token",
      refresh_token: "other-refresh-token"
    )

    assert_no_difference -> { ExternalIdentity.count } do
      assert_no_difference -> { @account.invoice_sources.xero.count } do
        assert_raises Xero::AccountConnection::TenantConflictError do
          connect
        end
      end
    end
  end

  test "requires an active membership in the target account" do
    @account.users.owner.sole.deactivate

    assert_no_connection_changes do
      assert_raises Xero::AccountConnection::ConnectionError do
        connect
      end
    end
  end

  test "allows an allowlisted platform administrator with an exact active impersonated user" do
    target_account, target_member = account_with_member(
      owner_email: "platform-target-owner@example.com",
      member_email: "platform-target-member@example.com"
    )
    PlatformAdminAccess.stubs(:allowed?).with(@identity).returns(true)

    result = Xero::AccountConnection.new(
      account: target_account,
      identity: @identity,
      authorization: @authorization,
      platform_admin_impersonated_user: target_member
    ).complete!

    assert_equal target_account, result.invoice_source.account
    assert_equal @identity, result.external_identity.identity
  end

  test "an ordinary identity cannot borrow another user's account access" do
    target_account, target_member = account_with_member(
      owner_email: "ordinary-target-owner@example.com",
      member_email: "ordinary-target-member@example.com"
    )
    PlatformAdminAccess.stubs(:allowed?).with(@identity).returns(false)

    assert_no_difference -> { target_account.invoice_sources.xero.count } do
      assert_raises Xero::AccountConnection::ConnectionError do
        Xero::AccountConnection.new(
          account: target_account,
          identity: @identity,
          authorization: @authorization,
          platform_admin_impersonated_user: target_member
        ).complete!
      end
    end
  end

  test "rolls back identity linking when the source cannot be connected" do
    InvoiceSources::Xero.any_instance.stubs(:connect_from_authorization!).raises("connection failed")

    assert_no_connection_changes do
      assert_raises RuntimeError do
        connect
      end
    end
  end

  private
    def connect(authorization: @authorization)
      Xero::AccountConnection.new(
        account: @account,
        identity: @identity,
        authorization:
      ).complete!
    end

    def authorization_result
      Xero::Authorization::Result.new(
        identity: Xero::VerifiedIdentity.new(
          subject: "xero-user-account-connection",
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
        connections: [ organization_connection ],
        authentication_event_id: "auth-event-account-connection"
      )
    end

    def account_with_member(owner_email:, member_email:)
      account = Account.create_with_owner(
        account: { name: "Impersonation target" },
        owner: {
          name: "Target Owner",
          identity: Identity.create!(email_address: owner_email)
        }
      )
      member = account.users.create!(
        name: "Target Member",
        role: :member,
        identity: Identity.create!(email_address: member_email)
      )

      [ account, member ]
    end

    def organization_connection(
      id: "connection-account-connection",
      tenant_id: "tenant-account-connection",
      tenant_type: "ORGANISATION",
      auth_event_id: "auth-event-account-connection"
    )
      {
        "id" => id,
        "authEventId" => auth_event_id,
        "tenantId" => tenant_id,
        "tenantType" => tenant_type,
        "tenantName" => "Account Connection Ltd"
      }
    end

    def assert_no_connection_changes(&)
      assert_no_difference -> { ExternalIdentity.count } do
        assert_no_difference -> { @account.invoice_sources.xero.count }, &
      end
    end
end
