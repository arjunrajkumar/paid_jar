require "test_helper"

class ConversationMessages::ManualReplyJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @connection = email_connections(:paid_jar_gmail)
    @anchor = @conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "job-anchor",
      provider_thread_id: "job-thread",
      internet_message_id: "<job-anchor@example.com>",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      from_address: @invoice.customer.email,
      subject: "Question",
      matching_status: :matched,
      matching_method: :gmail_thread
    )
    @conversation.update!(attention_required_at: @anchor.received_at)
  end

  test "confirmed delivery records the provider thread and clears attention" do
    ConversationMessages::ProviderDelivery.expects(:call).returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: "sent-reply",
        provider_thread_id: "job-thread",
        failure_reason: nil,
        delivery_uncertain: false
      )
    )

    perform_enqueued_jobs do
      @message = enqueue_reply("job-confirmed")
    end

    assert_predicate @message.reload, :status_sent?
    assert_equal "sent-reply", @message.provider_message_id
    assert_equal "job-thread", @message.provider_thread_id
    assert_nil @conversation.reload.attention_required_at
    assert_predicate @conversation.conversation_events
      .kind_conversation_manual_reply_sent
      .sole,
      :actor_kind_system?
  end

  test "unconfirmed delivery remains attention work" do
    ConversationMessages::ProviderDelivery.expects(:call).returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: nil,
        provider_thread_id: nil,
        failure_reason: "response lost",
        delivery_uncertain: true
      )
    )

    perform_enqueued_jobs do
      @message = enqueue_reply("job-unconfirmed")
    end

    assert_predicate @message.reload, :status_failed?
    assert_predicate @message, :delivery_uncertain?
    assert_equal ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
      @message.failure_reason
    assert @conversation.reload.attention_required_at
    assert_predicate @conversation.conversation_events
      .kind_conversation_manual_reply_unconfirmed
      .sole,
      :actor_kind_system?
  end

  test "confirmed delivery does not clear attention from a newer inbound message" do
    ConversationMessages::ProviderDelivery.expects(:call).returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: "sent-before-newer-inbound",
        provider_thread_id: "job-thread",
        failure_reason: nil,
        delivery_uncertain: false
      )
    )
    message = enqueue_reply("job-newer-inbound")
    newer_inbound = @conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "newer-job-inbound",
      provider_thread_id: "job-thread",
      internet_message_id: "<newer-job-inbound@example.com>",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.minute.from_now,
      from_address: @invoice.customer.email,
      matching_status: :matched,
      matching_method: :gmail_thread
    )
    @conversation.update!(attention_required_at: newer_inbound.received_at)

    perform_enqueued_jobs

    assert_predicate message.reload, :status_sent?
    assert_equal newer_inbound.received_at,
      @conversation.reload.attention_required_at
  end

  test "re-entry repairs missing sent audit and attention without sending twice" do
    ConversationMessages::ProviderDelivery.expects(:call).once.returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: "sent-before-finalization-failure",
        provider_thread_id: "job-thread",
        failure_reason: nil,
        delivery_uncertain: false
      )
    )
    message = enqueue_reply("repair-sent-outcome")
    ConversationEvent.stubs(:record_once!).raises(RuntimeError, "event store unavailable")

    assert_raises RuntimeError do
      perform_enqueued_jobs
    end

    assert_predicate message.reload, :status_sent?
    assert_empty message.conversation_events.kind_conversation_manual_reply_sent
    assert @conversation.reload.attention_required_at
    ConversationEvent.unstub(:record_once!)

    ConversationMessages::ManualReplyJob.perform_now(
      @account.id,
      message.id,
      message.requested_provider_thread_id
    )

    assert_predicate message.conversation_events
      .kind_conversation_manual_reply_sent
      .sole,
      :actor_kind_system?
    assert_nil @conversation.reload.attention_required_at
  end

  private
    def enqueue_reply(idempotency_key)
      ConversationMessages::ManualReply.enqueue!(
        conversation: @conversation,
        reply_to_message: @anchor,
        actor_user: users(:arjun),
        body: "Thanks for your message.",
        idempotency_key:,
        composer_token: ConversationMessages::ManualReply.composer_token_for(
          conversation: @conversation,
          target: ConversationMessages::ManualReply.reply_target_for(
            conversation: @conversation,
            reply_to_message: @anchor
          )
        )
      )
    end
end
