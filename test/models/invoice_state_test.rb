require "test_helper"

class InvoiceStateTest < ActiveSupport::TestCase
  test "belongs to an invoice and latest invoice event" do
    state = invoice_states(:xero_invoice_state)

    assert_equal invoices(:xero_invoice), state.invoice
    assert_equal invoice_events(:xero_needs_invoice_copy), state.latest_invoice_event
  end

  test "requires a customer situation and customer situation at" do
    state = invoices(:xero_invoice).build_invoice_state

    assert_not state.valid?
    assert_includes state.errors[:customer_situation], "can't be blank"
    assert_includes state.errors[:customer_situation_at], "can't be blank"
  end

  test "allows one state per invoice" do
    state = InvoiceState.new(
      invoice: invoices(:xero_invoice),
      customer_situation: "promise_to_pay",
      customer_situation_at: Time.current
    )

    assert_not state.valid?
    assert_includes state.errors[:invoice_id], "has already been taken"
  end

  test "latest invoice event must belong to the same invoice" do
    invoice = invoice_sources(:xero).invoices.create!(
      account: accounts(:paid_jar),
      external_id: "invoice-with-mismatched-state"
    )

    state = invoice.build_invoice_state(
      latest_invoice_event: invoice_events(:xero_needs_invoice_copy),
      customer_situation: "needs_invoice_copy",
      customer_situation_at: Time.current
    )

    assert_not state.valid?
    assert_includes state.errors[:latest_invoice_event], "must belong to invoice"
  end
end
