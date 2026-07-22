require "test_helper"

class InvoiceMessageTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
  end

  test "records a sent scheduled reminder email" do
    message = build_message

    assert message.save
    assert_predicate message, :direction_outbound?
    assert_predicate message, :kind_scheduled_reminder?
    assert_predicate message, :status_sent?
    assert_equal @invoice.account, message.account
    assert_equal @invoice, message.invoice
  end

  test "requires the account to match the invoice" do
    message = build_message(account: Account.create!(name: "Other Message Account"))

    assert_not message.valid?
    assert_includes message.errors[:account], "must match invoice account"
  end

  test "requires sent outbound messages to have a sent timestamp" do
    message = build_message(sent_at: nil)

    assert_not message.valid?
    assert_includes message.errors[:sent_at], "can't be blank"
  end

  test "requires received messages to be inbound and timestamped" do
    outbound_received = build_message(status: :received, sent_at: nil, received_at: Time.current)
    inbound_without_timestamp = build_message(
      direction: :inbound,
      status: :received,
      sent_at: nil,
      received_at: nil
    )

    assert_not outbound_received.valid?
    assert_includes outbound_received.errors[:status], "must be received only for inbound messages"
    assert_not inbound_without_timestamp.valid?
    assert_includes inbound_without_timestamp.errors[:received_at], "can't be blank"
  end

  test "finds every successful outbound email sent after a cutoff" do
    cutoff = Time.zone.local(2026, 7, 22, 12)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      recent = build_message(kind: :invoice_resend, sent_at: cutoff + 1.second)
      boundary = build_message(kind: :due_date_answer, sent_at: cutoff)
      failed = build_message(status: :failed, sent_at: nil, failure_reason: "Delivery failed")
      inbound = build_message(
        direction: :inbound,
        status: :received,
        sent_at: nil,
        received_at: Time.current
      )
      [ recent, boundary, failed, inbound ].each(&:save!)

      assert_equal [ recent ], @invoice.invoice_messages.successful_outbound.sent_after(cutoff)
    end
  end

  private
    def build_message(attributes = {})
      InvoiceMessage.new(
        {
          account: @invoice.account,
          invoice: @invoice,
          direction: :outbound,
          kind: :scheduled_reminder,
          status: :sent,
          sent_at: Time.current,
          from_address: "billing@paymentreminder.example",
          to_addresses: [ "customer@example.com" ],
          cc_addresses: [],
          subject: "Payment reminder",
          body: "Please pay invoice INV-001."
        }.merge(attributes)
      )
    end
end
