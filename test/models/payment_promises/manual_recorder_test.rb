require "test_helper"

class PaymentPromises::ManualRecorderTest < ActiveSupport::TestCase
  test "records an inbound message and active promise as one operation" do
    invoice = invoices(:xero_invoice)
    promised_on = Date.current + 5.days

    assert_difference -> { invoice.invoice_messages.count }, 1 do
      assert_difference -> { invoice.payment_promises.count }, 1 do
        promise = PaymentPromises::ManualRecorder.call(
          invoice:,
          promised_on:,
          note: "Customer called and committed to paying next week."
        )

        assert_predicate promise, :status_active?
        assert_equal promised_on, promise.promised_on
        assert_equal promised_on + 1.day, promise.follow_up_on
        assert_predicate promise.source_message, :direction_inbound?
        assert_predicate promise.source_message, :status_received?
        assert_predicate promise.source_message, :kind_customer_reply?
        assert_equal "Customer called and committed to paying next week.", promise.source_message.body
      end
    end
  end

  test "rolls back the source message when the promise is invalid" do
    invoice = invoices(:xero_invoice)

    assert_no_difference -> { invoice.invoice_messages.count } do
      assert_raises ActiveRecord::RecordInvalid do
        PaymentPromises::ManualRecorder.call(invoice:, promised_on: nil)
      end
    end
  end

  test "rejects a promise for a settled invoice" do
    invoice = invoices(:xero_invoice)
    invoice.update!(status: :paid, paid_on: Date.current, amount_due: 0)

    assert_no_difference [ -> { invoice.invoice_messages.count }, -> { invoice.payment_promises.count } ] do
      error = assert_raises ArgumentError do
        PaymentPromises::ManualRecorder.call(invoice:, promised_on: Date.current)
      end

      assert_equal "Payment promises can only be recorded for an outstanding invoice.", error.message
    end
  end
end
