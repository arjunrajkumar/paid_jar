require "test_helper"

class GmailAuthenticationMonitoringTest < ActiveJob::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @invoice.account.update!(automatic_invoice_reminders_enabled: true)
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
  end

  test "reports a handled Gmail authentication failure to Sentry" do
    authentication_error = EmailConnection::Errors::AuthenticationError.new("invalid_grant")
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver).raises(authentication_error)

    Sentry.expects(:capture_exception).with(
      authentication_error,
      tags: {
        provider: "gmail",
        operation: "invoice_reminder_delivery"
      },
      extra: {
        account_id: @invoice.account_id,
        invoice_id: @invoice.id
      }
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end
  end
end
