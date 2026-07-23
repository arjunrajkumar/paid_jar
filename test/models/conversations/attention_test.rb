require "test_helper"

class Conversations::AttentionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @connection = email_connections(:paid_jar_gmail)
    @actor = users(:arjun)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
  end

  test "reviewing newest-first moves attention backward and then clears it" do
    older = create_review_message(
      provider_message_id: "attention-older",
      provider_thread_id: "attention-thread-older",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    newer = create_review_message(
      provider_message_id: "attention-newer",
      provider_thread_id: "attention-thread-newer",
      received_at: Time.zone.local(2026, 7, 22, 12)
    )
    @conversation.update!(attention_required_at: newer.received_at)

    review(newer)
    assert_equal older.received_at, @conversation.reload.attention_required_at

    review(older)
    assert_nil @conversation.reload.attention_required_at
  end

  test "reviewing oldest-first retains newer attention and then clears it" do
    older = create_review_message(
      provider_message_id: "attention-oldest-first",
      provider_thread_id: "attention-oldest-thread",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    newer = create_review_message(
      provider_message_id: "attention-newest-last",
      provider_thread_id: "attention-newest-thread",
      received_at: Time.zone.local(2026, 7, 22, 12)
    )
    @conversation.update!(attention_required_at: newer.received_at)

    review(older)
    assert_equal newer.received_at, @conversation.reload.attention_required_at

    review(newer)
    assert_nil @conversation.reload.attention_required_at
  end

  test "an unrelated outbound does not clear a manually matched unanswered question" do
    source = @account.conversations.create!
    question = create_review_message(
      provider_message_id: "manual-question",
      provider_thread_id: "manual-question-thread",
      received_at: Time.zone.local(2026, 7, 22, 10),
      conversation: source
    )
    canonical = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: question,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )
    unrelated = canonical.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "unrelated-outbound",
      provider_thread_id: "unrelated-outbound-thread",
      direction: :outbound,
      kind: :manual_email,
      status: :sent,
      sent_at: Time.zone.local(2026, 7, 22, 12),
      from_address: @connection.connected_email,
      to_addresses: [ @invoice.customer.email ],
      matching_status: :matched,
      matching_method: :gmail_thread
    )

    Conversations::Attention.clear_for_outbound!(unrelated)

    assert_equal question.received_at, canonical.reload.attention_required_at
    assert_predicate question.reload, :review_outcome_manual_match?
  end

  test "a delayed import remains attention work until a later acknowledgement" do
    visible = create_customer_message(
      provider_message_id: "visible-before-handled",
      provider_thread_id: "delayed-import-thread",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    @conversation.update!(attention_required_at: visible.received_at)
    Conversations::Acknowledgement.call(
      conversation: @conversation,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(@conversation),
      at: Time.zone.local(2026, 7, 22, 12)
    )
    delayed = create_customer_message(
      provider_message_id: "delayed-after-handled",
      provider_thread_id: "delayed-import-thread",
      received_at: Time.zone.local(2026, 7, 22, 9)
    )

    Conversations::Attention.require_for_message!(delayed)
    Conversations::Attention.recompute!(conversation: @conversation)

    assert_equal delayed.received_at,
      @conversation.reload.attention_required_at
    Conversations::Acknowledgement.call(
      conversation: @conversation,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(@conversation)
    )
    assert_nil @conversation.reload.attention_required_at
  end

  test "acknowledgement visibility ordering is deterministic for equal timestamps" do
    first = create_customer_message(
      provider_message_id: "equal-time-visible",
      provider_thread_id: "equal-time-thread",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    @conversation.update!(attention_required_at: first.received_at)
    Conversations::Acknowledgement.call(
      conversation: @conversation,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(@conversation)
    )
    later = create_customer_message(
      provider_message_id: "equal-time-later",
      provider_thread_id: "equal-time-thread",
      received_at: first.received_at
    )

    Conversations::Attention.require_for_message!(later)
    Conversations::Attention.recompute!(conversation: @conversation)

    assert_equal later.received_at,
      @conversation.reload.attention_required_at
  end

  test "acknowledgement covers exact visible membership instead of older IDs linked later" do
    source = @account.conversations.create!
    older = create_review_message(
      provider_message_id: "older-linked-after-ack",
      provider_thread_id: "older-linked-after-ack-thread",
      received_at: Time.zone.local(2026, 7, 22, 9),
      conversation: source
    )
    visible = create_customer_message(
      provider_message_id: "visible-before-link",
      provider_thread_id: "visible-before-link-thread",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    @conversation.update!(attention_required_at: visible.received_at)

    Conversations::Acknowledgement.call(
      conversation: @conversation,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(@conversation)
    )
    canonical = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: older,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )

    assert_equal older.received_at, canonical.reload.attention_required_at

    Conversations::Acknowledgement.call(
      conversation: canonical,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(canonical)
    )

    assert_nil canonical.reload.attention_required_at
  end

  test "a definite manual-reply failure after acknowledgement reopens attention" do
    assert_reply_outcome_reopens_attention(delivery_uncertain: false)
  end

  test "an unconfirmed manual reply after acknowledgement reopens attention" do
    assert_reply_outcome_reopens_attention(delivery_uncertain: true)
  end

  test "a successful manual reply after acknowledgement stays handled" do
    anchor = create_customer_message(
      provider_message_id: "successful-after-handled-anchor",
      provider_thread_id: "successful-after-handled-thread",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    @conversation.update!(attention_required_at: anchor.received_at)
    reply = enqueue_reply(anchor, "successful-after-handled")
    Conversations::Acknowledgement.call(
      conversation: @conversation,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(@conversation)
    )

    reply.mark_delivery_sent!(
      job_id: reply.delivery_job_id,
      sent_at: Time.zone.local(2026, 7, 22, 12),
      provider_message_id: "successful-after-handled-provider",
      provider_thread_id: anchor.provider_thread_id
    )
    ConversationMessages::ManualReplyOutcome.finalize!(reply)

    assert_nil @conversation.reload.attention_required_at
  end

  private
    def review(message)
      ConversationMessages::Review.complete!(
        conversation: message.conversation.canonical,
        message:,
        actor_user: @actor,
        outcome: :no_match_needed,
        work_unit_token: conversation_work_unit_token(
          message.conversation.canonical
        )
      )
    end

    def create_review_message(
      provider_message_id:,
      provider_thread_id:,
      received_at:,
      conversation: @conversation
    )
      conversation.conversation_messages.create!(
        account: @account,
        invoice: conversation.invoice,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id:,
        internet_message_id: "<#{provider_message_id}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at:,
        from_address: @invoice.customer.email,
        matching_status: :ambiguous,
        matching_method: :none,
        review_required: true,
        review_reasons: [ "invoice_unmatched" ]
      )
    end

    def create_customer_message(provider_message_id:, provider_thread_id:, received_at:)
      @conversation.conversation_messages.create!(
        account: @account,
        invoice: @invoice,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id:,
        internet_message_id: "<#{provider_message_id}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at:,
        from_address: @invoice.customer.email,
        matching_status: :matched,
        matching_method: :gmail_thread
      )
    end

    def enqueue_reply(anchor, idempotency_key)
      ConversationMessages::ManualReply.enqueue!(
        conversation: @conversation,
        reply_to_message: anchor,
        actor_user: @actor,
        body: "A reply outcome that needs attention.",
        idempotency_key:,
        composer_token: ConversationMessages::ManualReply.composer_token_for(
          conversation: @conversation,
          target: ConversationMessages::ManualReply.reply_target_for(
            conversation: @conversation,
            reply_to_message: anchor
          )
        )
      ).tap { clear_enqueued_jobs }
    end

    def assert_reply_outcome_reopens_attention(delivery_uncertain:)
      anchor = create_customer_message(
        provider_message_id: "failed-after-handled-#{delivery_uncertain}",
        provider_thread_id: "failed-after-handled-#{delivery_uncertain}",
        received_at: Time.zone.local(2026, 7, 22, 10)
      )
      @conversation.update!(attention_required_at: anchor.received_at)
      reply = enqueue_reply(anchor, "failed-after-handled-#{delivery_uncertain}")
      Conversations::Acknowledgement.call(
        conversation: @conversation,
        actor_user: @actor,
        work_unit_token: conversation_work_unit_token(@conversation)
      )
      reply.mark_delivery_failed!(
        job_id: reply.delivery_job_id,
        failure_reason: "Gmail delivery failed.",
        delivery_uncertain:
      )

      ConversationMessages::ManualReplyOutcome.finalize!(reply)

      assert_equal anchor.received_at,
        @conversation.reload.attention_required_at
      event_count = reply.conversation_events.count
      Conversations::Acknowledgement.call(
        conversation: @conversation,
        actor_user: @actor,
        work_unit_token: conversation_work_unit_token(@conversation)
      )
      ConversationMessages::ManualReplyOutcome.finalize!(reply)
      assert_nil @conversation.reload.attention_required_at
      assert_equal event_count, reply.conversation_events.count
    end
end
