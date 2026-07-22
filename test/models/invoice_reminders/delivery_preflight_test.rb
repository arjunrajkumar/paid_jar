require "test_helper"

class InvoiceReminders::DeliveryPreflightTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @invoice.account.update!(automatic_invoice_reminders_enabled: true)
  end

  test "persists a durable suppression after rechecking under the invoice lock" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      create_recent_message

      assert_difference -> { @invoice.invoice_reminder_suppressions.count }, 1 do
        @decision = preflight
      end
    end

    assert_predicate @decision, :suppression?
    assert_equal "recent_outbound_message", @decision.reason
    assert_predicate @invoice.invoice_reminder_suppressions.last,
      :reason_recent_outbound_message?
  end

  test "returns an ordinary eligibility decision without writing suppression" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { @invoice.invoice_reminder_suppressions.count } do
        @decision = preflight
      end
    end

    assert_predicate @decision, :deliverable?
  end

  private
    def preflight
      InvoiceReminders::DeliveryPreflight.call(
        invoice: @invoice.reload,
        category: :pre_due,
        day_offset: 7,
        delivery_job_id: "preflight-job"
      )
    end

    def create_recent_message
      @invoice.conversation_messages.create!(
        account: @invoice.account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction: :outbound,
        kind: :invoice_resend,
        status: :sent,
        sent_at: 1.hour.ago,
        provider_message_id: "delivery-preflight-recent-message",
        from_address: "billing@paymentreminder.example",
        to_addresses: [ "customer@example.com" ],
        cc_addresses: [],
        subject: "Invoice INV-001",
        body: "Here is the invoice."
      )
    end
end
