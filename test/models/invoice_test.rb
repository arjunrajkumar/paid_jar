require "test_helper"

class InvoiceTest < ActiveSupport::TestCase
  test "belongs to an account and invoice source" do
    invoice = invoices(:xero_invoice)

    assert_equal accounts(:paid_jar), invoice.account
    assert_equal invoice_sources(:xero), invoice.invoice_source
  end

  test "has invoice events and invoice state" do
    invoice = invoices(:xero_invoice)

    assert_includes invoice.invoice_events, invoice_events(:xero_needs_invoice_copy)
    assert_equal invoice_states(:xero_invoice_state), invoice.invoice_state
  end

  test "requires an external id" do
    invoice = invoice_sources(:xero).invoices.build(account: accounts(:paid_jar))

    assert_not invoice.valid?
    assert_includes invoice.errors[:external_id], "can't be blank"
  end

  test "does not allow the same external id twice for a source" do
    invoice = invoice_sources(:xero).invoices.build(
      account: accounts(:paid_jar),
      external_id: invoices(:xero_invoice).external_id
    )

    assert_not invoice.valid?
    assert_includes invoice.errors[:external_id], "has already been taken"
  end
end
