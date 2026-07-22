require "test_helper"

class InvoiceReminders::ManualDeliveryReservationTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @account.update!(automatic_invoice_reminders_enabled: false)
  end

  test "reserves a manual reminder while automatic reminders are disabled" do
    assert_difference -> { @invoice.conversation_messages.count }, 1 do
      @result = reserve
    end

    assert_predicate @result, :reserved?
    assert_equal email_connections(:paid_jar_gmail), @result.connection
    assert_equal Conversation.for_invoice!(invoice: @invoice), @result.message.conversation
    assert_equal "manual_reminder", @result.message.kind
    assert_predicate @result.message, :status_pending?
    assert_equal "manual-reminder-job", @result.message.delivery_job_id
    assert_equal [ "customer@example.com" ], @result.message.to_addresses
    assert_match(/INV-001/, @result.message.subject)
  end

  test "does not reserve a reminder for a settled invoice" do
    @invoice.update!(status: :paid, paid_on: Date.current, amount_due: 0)

    result = reserve

    assert_not_predicate result, :reserved?
    assert_equal "not_outstanding", result.reason
    assert_nil result.message
  end

  test "does not reserve without a valid customer recipient" do
    @invoice.customer.update!(email: nil)

    result = reserve

    assert_not_predicate result, :reserved?
    assert_equal "missing_email", result.reason
  end

  test "reuses only the pending delivery owned by the same job" do
    first_result = reserve

    retry_result = reserve
    other_job_result = reserve(delivery_job_id: "another-job")

    assert_predicate retry_result, :reserved?
    assert_equal first_result.message, retry_result.message
    assert_not_predicate other_job_result, :reserved?
    assert_equal "outbound_delivery_in_progress", other_job_result.reason
  end

  private
    def reserve(delivery_job_id: "manual-reminder-job")
      InvoiceReminders::ManualDeliveryReservation.call(
        invoice: @invoice,
        delivery_job_id:
      )
    end
end
