require "test_helper"

class ConversationMessageTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
  end

  test "records a sent scheduled reminder email" do
    message = build_message

    assert message.save
    assert_predicate message, :direction_outbound?
    assert_predicate message, :kind_scheduled_reminder?
    assert_predicate message, :status_sent?
    assert_equal @invoice.account, message.account
    assert_equal @invoice, message.invoice
    assert_equal @conversation, message.conversation
  end

  test "requires a conversation" do
    message = build_message(conversation: nil)

    assert_not message.valid?
    assert_includes message.errors[:conversation], "must exist"
  end

  test "requires the account to match the invoice" do
    message = build_message(account: Account.create!(name: "Other Message Account"))

    assert_not message.valid?
    assert_includes message.errors[:account], "must match invoice account"
  end

  test "requires the account to match the conversation" do
    unmatched_conversation = Conversation.create!(account: Account.create!(name: "Other Conversation Account"))
    message = build_message(
      conversation: unmatched_conversation,
      invoice: nil,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      sent_at: nil,
      received_at: Time.current
    )

    assert_not message.valid?
    assert_includes message.errors[:account], "must match conversation account"
  end

  test "requires the invoice to match an invoice-backed conversation" do
    other_invoice = @invoice.dup
    other_invoice.external_id = "conversation-message-other-invoice"
    other_invoice.save!
    message = build_message(invoice: other_invoice)

    assert_not message.valid?
    assert_includes message.errors[:invoice], "must match conversation invoice"
  end

  test "rejects an invoice on an unmatched conversation" do
    message = build_message(conversation: Conversation.create!(account: @invoice.account))

    assert_not message.valid?
    assert_includes message.errors[:invoice], "must be blank for an unmatched conversation"
  end

  test "stores a received customer email without an invoice in an unmatched conversation" do
    unmatched_conversation = Conversation.create!(account: @invoice.account)
    message = build_message(
      conversation: unmatched_conversation,
      invoice: nil,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      sent_at: nil,
      received_at: Time.current
    )

    assert message.save
    assert_nil message.invoice
    assert_equal unmatched_conversation, message.conversation
    assert_predicate message, :kind_customer_email?
  end

  test "rejects an invoice-less outbound message" do
    message = build_message(
      conversation: Conversation.create!(account: @invoice.account),
      invoice: nil
    )

    assert_not message.valid?
    assert_includes message.errors[:invoice],
      "is required unless this is a received customer email in an unmatched conversation"
  end

  test "rejects an invoice-less inbound collection message" do
    message = build_message(
      conversation: Conversation.create!(account: @invoice.account),
      invoice: nil,
      direction: :inbound,
      kind: :customer_reply,
      status: :received,
      sent_at: nil,
      received_at: Time.current
    )

    assert_not message.valid?
    assert_includes message.errors[:invoice],
      "is required unless this is a received customer email in an unmatched conversation"
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

  test "rejects timestamps that contradict the delivery status" do
    pending = build_message(status: :pending, sent_at: Time.current)
    failed = build_message(status: :failed, sent_at: Time.current)
    received = build_message(
      direction: :inbound,
      status: :received,
      sent_at: Time.current,
      received_at: Time.current
    )

    assert_not pending.valid?
    assert_includes pending.errors[:sent_at], "must be blank until the message is sent"
    assert_not failed.valid?
    assert_includes failed.errors[:sent_at], "must be blank until the message is sent"
    assert_not received.valid?
    assert_includes received.errors[:sent_at], "must be blank for received messages"
  end

  test "successful messages cannot retain a failure reason" do
    message = build_message(failure_reason: "Old failure")

    assert_not message.valid?
    assert_includes message.errors[:failure_reason], "must be blank for successful messages"
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

      assert_equal [ recent ], @invoice.conversation_messages.successful_outbound.sent_after(cutoff)
    end
  end

  test "recognizes only the pending delivery's owning job" do
    pending = build_message(
      status: :pending,
      sent_at: nil,
      delivery_job_id: "delivery-job-123"
    )
    pending.save!
    sent = build_message(delivery_job_id: "delivery-job-123")
    sent.save!

    assert pending.delivery_owned_by?("delivery-job-123")
    assert pending.delivery_owned_by?(" delivery-job-123 ")
    assert_not pending.delivery_owned_by?("another-job")
    assert_not pending.delivery_owned_by?(nil)
    assert_not sent.delivery_owned_by?("delivery-job-123")
  end

  test "refreshes an owned pending delivery from the current mail message" do
    message = build_message(
      status: :pending,
      sent_at: nil,
      delivery_job_id: "delivery-job-123",
      delivery_attempted_at: 1.hour.ago
    )
    message.save!
    attempted_at = Time.zone.local(2026, 7, 22, 14)
    mail_message = multipart_mail

    assert message.refresh_delivery_attempt!(
      job_id: "delivery-job-123",
      mail_message:,
      attempted_at:
    )

    message.reload
    assert_predicate message, :status_pending?
    assert_equal attempted_at, message.delivery_attempted_at
    assert_equal "billing@example.com", message.from_address
    assert_equal [ "customer@example.com" ], message.to_addresses
    assert_equal [ "accounts@example.com" ], message.cc_addresses
    assert_equal "Updated payment reminder", message.subject
    assert_equal "Please pay the updated balance.", message.body
  end

  test "does not refresh delivery content for a different job" do
    message = build_message(
      status: :pending,
      sent_at: nil,
      delivery_job_id: "delivery-job-123",
      delivery_attempted_at: 1.hour.ago
    )
    message.save!
    original_attributes = message.attributes.slice(
      "delivery_attempted_at",
      "from_address",
      "to_addresses",
      "cc_addresses",
      "subject",
      "body"
    )

    assert_not message.refresh_delivery_attempt!(
      job_id: "another-job",
      mail_message: multipart_mail,
      attempted_at: Time.current
    )
    assert_equal original_attributes, message.reload.attributes.slice(*original_attributes.keys)
  end

  test "marks an owned pending delivery sent with provider metadata" do
    message = build_message(
      status: :pending,
      sent_at: nil,
      delivery_job_id: "delivery-job-123",
      delivery_attempted_at: 1.minute.ago,
      failure_reason: "Previous attempt failed"
    )
    message.save!
    sent_at = Time.zone.local(2026, 7, 22, 15)

    assert message.mark_delivery_sent!(
      job_id: "delivery-job-123",
      sent_at:,
      provider_message_id: "gmail-message-123",
      provider_thread_id: "gmail-thread-456"
    )

    message.reload
    assert_predicate message, :status_sent?
    assert_equal sent_at, message.sent_at
    assert_equal "gmail-message-123", message.provider_message_id
    assert_equal "gmail-thread-456", message.provider_thread_id
    assert_nil message.failure_reason
    assert_equal "delivery-job-123", message.delivery_job_id
  end

  test "marks an owned pending delivery failed and clears unconfirmed provider metadata" do
    message = build_message(
      status: :pending,
      sent_at: nil,
      delivery_job_id: "delivery-job-123",
      provider_message_id: "unconfirmed-message",
      provider_thread_id: "unconfirmed-thread"
    )
    message.save!

    assert message.mark_delivery_failed!(
      job_id: "delivery-job-123",
      failure_reason: "Delivery timed out"
    )

    message.reload
    assert_predicate message, :status_failed?
    assert_equal "Delivery timed out", message.failure_reason
    assert_nil message.provider_message_id
    assert_nil message.provider_thread_id
    assert_nil message.sent_at
  end

  test "terminal transitions reject another job and an already terminal message" do
    pending = build_message(
      status: :pending,
      sent_at: nil,
      delivery_job_id: "delivery-job-123"
    )
    pending.save!
    sent = build_message(
      delivery_job_id: "delivery-job-123",
      provider_message_id: "original-provider-message"
    )
    sent.save!

    assert_not pending.mark_delivery_sent!(
      job_id: "another-job",
      provider_message_id: "wrong-provider-message"
    )
    assert_predicate pending.reload, :status_pending?
    assert_nil pending.provider_message_id

    assert_not sent.mark_delivery_failed!(
      job_id: "delivery-job-123",
      failure_reason: "Late failure"
    )
    assert_predicate sent.reload, :status_sent?
    assert_equal "original-provider-message", sent.provider_message_id
    assert_nil sent.failure_reason
  end

  private
    def build_message(attributes = {})
      ConversationMessage.new(
        {
          account: @invoice.account,
          conversation: @conversation,
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

    def multipart_mail
      Mail.new do
        from "billing@example.com"
        to "customer@example.com"
        cc "accounts@example.com"
        subject "Updated payment reminder"

        text_part do
          body "Please pay the updated balance."
        end

        html_part do
          content_type "text/html; charset=UTF-8"
          body "<p>Please pay the updated balance.</p>"
        end
      end
    end
end
