require "test_helper"

class InvoiceEventTest < ActiveSupport::TestCase
  test "belongs to an invoice" do
    event = invoice_events(:xero_needs_invoice_copy)

    assert_equal invoices(:xero_invoice), event.invoice
  end

  test "requires a situation and asked at" do
    event = invoices(:xero_invoice).invoice_events.build

    assert_not event.valid?
    assert_includes event.errors[:situation], "can't be blank"
    assert_includes event.errors[:asked_at], "can't be blank"
  end
end
