require "test_helper"

class PlatformAdminAccessTest < ActiveSupport::TestCase
  test "allows only normalized configured email addresses" do
    identity = Identity.new(email_address: "owner@example.com")

    assert PlatformAdminAccess.allowed?(identity, email_addresses: [ "owner@example.com" ])
    assert_not PlatformAdminAccess.allowed?(identity, email_addresses: [ "someone-else@example.com" ])
    assert_not PlatformAdminAccess.allowed?(nil, email_addresses: [ "owner@example.com" ])
  end

  test "combines environment and credential email addresses" do
    credentials = { platform_admin: { email_addresses: [ " Credential@Example.com " ] } }
    environment = {
      "PLATFORM_ADMIN_EMAIL_ADDRESSES" => "first@example.com, SECOND@example.com\nfirst@example.com"
    }

    assert_equal(
      [ "first@example.com", "second@example.com", "credential@example.com" ],
      PlatformAdminAccess.configured_email_addresses(environment:, credentials:)
    )
  end

  test "fails closed without configured email addresses" do
    assert_empty PlatformAdminAccess.configured_email_addresses(environment: {}, credentials: {})
  end
end
