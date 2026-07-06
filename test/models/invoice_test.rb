require "test_helper"

class InvoiceTest < ActiveSupport::TestCase
  test "belongs to an account and accounting integration" do
    invoice = invoices(:xero_invoice)

    assert_equal accounts(:paid_jar), invoice.account
    assert_equal accounting_integrations(:xero), invoice.accounting_integration
  end

  test "requires an external id" do
    invoice = accounting_integrations(:xero).invoices.build(account: accounts(:paid_jar))

    assert_not invoice.valid?
    assert_includes invoice.errors[:external_id], "can't be blank"
  end

  test "does not allow the same external id twice for an integration" do
    invoice = accounting_integrations(:xero).invoices.build(
      account: accounts(:paid_jar),
      external_id: invoices(:xero_invoice).external_id
    )

    assert_not invoice.valid?
    assert_includes invoice.errors[:external_id], "has already been taken"
  end
end
