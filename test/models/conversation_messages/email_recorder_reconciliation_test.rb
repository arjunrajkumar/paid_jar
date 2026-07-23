require "test_helper"

class ConversationMessages::EmailRecorderReconciliationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @connection = email_connections(:paid_jar_gmail)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @anchor = @conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "reconcile-anchor",
      provider_thread_id: "reconcile-thread",
      internet_message_id: "<reconcile-anchor@example.com>",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.hour.ago,
      from_address: @invoice.customer.email,
      subject: "Question about INV-001",
      matching_status: :matched,
      matching_method: :gmail_thread
    )
    target = ConversationMessages::ManualReply.reply_target_for(
      conversation: @conversation,
      reply_to_message: @anchor
    )
    @reply = ConversationMessages::ManualReply.enqueue!(
      conversation: @conversation,
      reply_to_message: @anchor,
      actor_user: users(:arjun),
      body: "Thanks for your message.",
      idempotency_key: "reconcile-reply",
      composer_token: ConversationMessages::ManualReply.composer_token_for(
        conversation: @conversation,
        target:
      )
    )
    clear_enqueued_jobs
    @reply.refresh_delivery_attempt!(
      job_id: @reply.delivery_job_id,
      mail_message: Mail.new,
      attempted_at: 5.minutes.ago
    )
    @reply.mark_delivery_failed!(
      job_id: @reply.delivery_job_id,
      failure_reason: ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
      delivery_uncertain: true
    )
    @conversation.update!(attention_required_at: @anchor.received_at)
  end

  test "Gmail SENT ingestion reconciles an unconfirmed app reply by stable RFC Message-ID" do
    ConversationMessages::ManualReplyOutcome.finalize!(@reply)
    assert_equal @anchor.received_at,
      @conversation.reload.attention_required_at
    assert_predicate @reply.conversation_events
      .kind_conversation_manual_reply_unconfirmed
      .sole,
      :actor_kind_system?

    receipt = @connection.email_message_receipts.create!(
      account: @account,
      provider_message_id: "gmail-confirmed-reply",
      discovered_at: Time.current
    )
    receipt.claim!(job_id: "reconcile-receipt")

    assert_no_difference -> { ConversationMessage.count } do
      EmailMessageReceipts::Processor.call(
        receipt,
        job_id: "reconcile-receipt",
        mailbox: FakeMailbox.new(gmail_message)
      )
    end

    @reply.reload
    assert_predicate @reply, :status_sent?
    assert_equal "gmail-confirmed-reply", @reply.provider_message_id
    assert_equal "reconcile-thread", @reply.provider_thread_id
    assert_not_predicate @reply, :delivery_uncertain?
    assert_nil @reply.failure_reason
    assert_nil @conversation.reload.attention_required_at
    assert_equal @reply, receipt.reload.conversation_message
    assert_predicate @conversation.conversation_events
      .kind_conversation_manual_reply_sent
      .sole,
      :actor_kind_system?
    assert_predicate @reply.conversation_events
      .kind_conversation_manual_reply_unconfirmed
      .sole,
      :actor_kind_system?

    parsed_message = EmailConnection::Gmail::MessageParser.call(gmail_message)
    assert_no_difference -> { @reply.conversation_events.count } do
      assert @reply.reconcile_imported_manual_reply!(
        receipt:,
        parsed_message:,
        provider_account_id: @connection.provider_account_id
      )
      ConversationMessages::ManualReplyOutcome.finalize!(@reply)
    end
    assert_nil @conversation.reload.attention_required_at
  end

  private
    def gmail_message
      Google::Apis::GmailV1::Message.new(
        id: "gmail-confirmed-reply",
        thread_id: "reconcile-thread",
        internal_date: (Time.current.to_f * 1000).to_i.to_s,
        label_ids: [ "SENT" ],
        payload: Google::Apis::GmailV1::MessagePart.new(
          mime_type: "text/plain",
          headers: {
            "From" => @connection.connected_email,
            "To" => @invoice.customer.email,
            "Subject" => "Re: Question about INV-001",
            "Message-ID" => @reply.internet_message_id,
            "In-Reply-To" => @anchor.internet_message_id,
            "References" => @anchor.internet_message_id
          }.map do |name, value|
            Google::Apis::GmailV1::MessagePartHeader.new(name:, value:)
          end,
          body: Google::Apis::GmailV1::MessagePartBody.new(
            data: @reply.body
          )
        )
      )
    end

    class FakeMailbox
      def initialize(message)
        @message = message
      end

      def message(id:)
        raise "unexpected message" unless id == @message.id

        @message
      end
    end
end
