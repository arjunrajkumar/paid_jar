require "test_helper"

class AccountingIntegrationTest < ActiveSupport::TestCase
  test "belongs to an account" do
    assert_equal accounts(:paid_jar), accounting_integrations(:xero).account
  end

  test "has many invoices" do
    assert_includes accounting_integrations(:xero).invoices, invoices(:xero_invoice)
  end

  test "requires provider and external account id" do
    integration = accounts(:paid_jar).accounting_integrations.build

    assert_not integration.valid?
    assert_includes integration.errors[:provider], "can't be blank"
    assert_includes integration.errors[:external_account_id], "can't be blank"
  end

  test "defaults to pending status" do
    integration = accounts(:paid_jar).accounting_integrations.build(
      provider: "xero",
      external_account_id: "xero-tenant-456"
    )

    assert_predicate integration, :pending?
  end

  test "knows whether it is connected" do
    assert_predicate accounting_integrations(:xero), :connected?
  end

  test "does not allow the same provider twice for an account" do
    integration = accounts(:paid_jar).accounting_integrations.build(
      provider: "xero",
      external_account_id: "different-xero-tenant"
    )

    assert_not integration.valid?
    assert_includes integration.errors[:provider], "has already been taken"
  end
end
