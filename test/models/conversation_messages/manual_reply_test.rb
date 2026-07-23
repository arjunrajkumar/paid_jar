require "test_helper"

class ConversationMessages::ManualReplyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @actor = users(:arjun)
    @connection = email_connections(:paid_jar_gmail)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @anchor = create_anchor(received_at: Time.zone.local(2026, 7, 22, 10))
    @conversation.update!(attention_required_at: @anchor.received_at)
  end

  test "persists a complete server-derived threaded reply before enqueueing once" do
    message = nil

    assert_enqueued_with(job: ConversationMessages::ManualReplyJob) do
      assert_difference -> { ConversationMessage.kind_manual_reply.count }, 1 do
        message = ConversationMessages::ManualReply.enqueue!(
          conversation: @conversation,
          reply_to_message: @anchor,
          actor_user: @actor,
          body: "Thanks — we will check and come back to you.",
          idempotency_key: "manual-reply-once",
          composer_token: composer_token_for(@conversation, @anchor)
        )
      end
    end

    assert_equal @conversation, message.conversation
    assert_equal @invoice, message.invoice
    assert_equal @anchor, message.reply_to_message
    assert_equal @actor, message.actor_user
    assert_equal [ @invoice.customer.email ], message.to_addresses
    assert_equal "Re: Question about INV-001", message.subject
    assert_equal [ @anchor.internet_message_id ], message.in_reply_to_message_ids
    assert_equal [ @anchor.internet_message_id ], message.reference_message_ids
    assert_equal @anchor.provider_thread_id, message.requested_provider_thread_id
    assert_equal @anchor.provider_account_id, message.requested_provider_account_id
    assert_equal @connection, message.email_connection
    assert_predicate message, :status_pending?

    assert_no_enqueued_jobs do
      assert_no_difference -> { ConversationMessage.count } do
        assert_equal message, ConversationMessages::ManualReply.enqueue!(
          conversation: @conversation,
          reply_to_message: @anchor,
          actor_user: @actor,
          body: "Thanks — we will check and come back to you.",
          idempotency_key: "manual-reply-once",
          composer_token: composer_token_for(@conversation, @anchor)
        )
      end
    end
  end

  test "rejects an idempotency token reused for a different reply request" do
    enqueue_reply("manual-reply-conflict")

    assert_raises ConversationMessages::ManualReply::IdempotencyConflict do
      ConversationMessages::ManualReply.enqueue!(
        conversation: @conversation,
        reply_to_message: @anchor,
        actor_user: @actor,
        body: "A different reply body",
        idempotency_key: "manual-reply-conflict",
        composer_token: composer_token_for(@conversation, @anchor)
      )
    end
  end

  test "rejects stale, unsafe, and review-required reply anchors" do
    create_anchor(
      provider_message_id: "newer-anchor",
      internet_message_id: "<newer-anchor@example.com>",
      received_at: Time.zone.local(2026, 7, 22, 11)
    )

    assert_raises ConversationMessages::ManualReply::StaleComposer do
      enqueue_reply("stale-reply")
    end

    @anchor.update!(review_required: true)
    assert_raises ConversationMessages::ManualReply::UnsafeAnchor do
      ConversationMessages::ManualReply.enqueue!(
        conversation: @conversation,
        reply_to_message: @anchor,
        actor_user: @actor,
        body: "Do not send",
        idempotency_key: "unsafe-reply",
        composer_token: composer_token_for(@conversation, @anchor)
      )
    end
  end

  test "an enqueue failure leaves a failed ledger row and retains attention" do
    ConversationMessages::ManualReplyJob.any_instance.stubs(:enqueue).returns(false)

    message = assert_difference -> { ConversationMessage.kind_manual_reply.count }, 1 do
      enqueue_reply("enqueue-failure")
    end

    assert_predicate message.reload, :status_failed?
    assert_equal "Reply could not be queued.", message.failure_reason
    assert @conversation.reload.attention_required_at
    assert_predicate @conversation.conversation_events
      .kind_conversation_manual_reply_failed
      .sole,
      :actor_kind_system?
  end

  test "an unresolved delivery-unconfirmed reply blocks another reply to the thread" do
    message = enqueue_reply("unconfirmed-conflict")
    message.update!(
      status: :failed,
      failure_reason: ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
      delivery_uncertain: true
    )

    error = assert_raises ConversationMessages::ManualReply::StaleComposer do
      enqueue_reply("duplicate-after-unconfirmed")
    end

    assert_equal "Another reply may already have been sent for this thread.", error.message
  end

  test "newer inbound mail in another thread does not stale a valid reply anchor" do
    create_anchor(
      provider_message_id: "other-thread-message",
      provider_thread_id: "other-thread",
      internet_message_id: "<other-thread-message@example.com>",
      received_at: Time.zone.local(2026, 7, 22, 11)
    )

    assert_enqueued_with(job: ConversationMessages::ManualReplyJob) do
      assert_predicate enqueue_reply("thread-local-freshness"), :status_pending?
    end
  end

  test "a same-thread inbound with the same timestamp and a higher ID stales the older anchor" do
    create_anchor(
      provider_message_id: "same-time-newer-anchor",
      internet_message_id: "<same-time-newer-anchor@example.com>",
      received_at: @anchor.received_at
    )

    assert_raises ConversationMessages::ManualReply::StaleComposer do
      enqueue_reply("same-time-stale-anchor")
    end
  end

  test "projects and persists the exact verified Reply-To recipient" do
    @anchor.update!(reply_to_addresses: [ @invoice.customer.email.upcase ])

    assert_equal @invoice.customer.email,
      ConversationMessages::ManualReply.recipient_for(
        conversation: @conversation,
        reply_to_message: @anchor
      )
    assert_equal [ @invoice.customer.email ],
      enqueue_reply("reply-to-recipient").to_addresses
  end

  test "exact replay ignores mutable Gmail credentials and customer addresses" do
    composer_token = composer_token_for(@conversation, @anchor)
    message = enqueue_reply("mutable-replay")
    @connection.connect_gmail!(
      email: @connection.connected_email,
      name: @connection.provider_display_name,
      provider_account_id: @connection.provider_account_id,
      history_id: @connection.inbound_cursor,
      access_token: "rotated-access-token",
      refresh_token: "rotated-refresh-token",
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )
    @invoice.customer.update!(email: "changed-customer@example.com")
    @connection.disconnect!

    assert_equal message, ConversationMessages::ManualReply.enqueue!(
      conversation: @conversation,
      reply_to_message: @anchor,
      actor_user: @actor,
      body: "Reply body",
      idempotency_key: "mutable-replay",
      composer_token:
    )
  end

  test "idempotency rejects a different anchor conversation or actor" do
    composer_token = composer_token_for(@conversation, @anchor)
    enqueue_reply("immutable-request-identity")
    other_anchor = create_anchor(
      provider_message_id: "different-idempotency-anchor",
      provider_thread_id: "different-idempotency-thread",
      internet_message_id: "<different-idempotency-anchor@example.com>",
      received_at: @anchor.received_at - 1.minute
    )
    other_conversation = @account.conversations.create!
    other_actor = @account.users.create!(
      name: "Other reply actor",
      role: :member,
      verified_at: Time.current
    )

    [
      {
        conversation: @conversation,
        reply_to_message: other_anchor,
        actor_user: @actor
      },
      {
        conversation: other_conversation,
        reply_to_message: @anchor,
        actor_user: @actor
      },
      {
        conversation: @conversation,
        reply_to_message: @anchor,
        actor_user: other_actor
      }
    ].each do |attributes|
      assert_raises(
        ConversationMessages::ManualReply::IdempotencyConflict,
        ActiveRecord::RecordNotFound
      ) do
        ConversationMessages::ManualReply.enqueue!(
          **attributes,
          body: "Reply body",
          idempotency_key: "immutable-request-identity",
          composer_token:
        )
      end
    end
  end

  private
    def enqueue_reply(idempotency_key)
      ConversationMessages::ManualReply.enqueue!(
        conversation: @conversation,
        reply_to_message: @anchor,
        actor_user: @actor,
        body: "Reply body",
        idempotency_key:,
        composer_token: composer_token_for(@conversation, @anchor)
      )
    end

    def composer_token_for(conversation, anchor)
      target = ConversationMessages::ManualReply.reply_target_for(
        conversation:,
        reply_to_message: anchor
      )
      ConversationMessages::ManualReply.composer_token_for(
        conversation:,
        target:
      )
    end

    def create_anchor(
      provider_message_id: "reply-anchor",
      provider_thread_id: "reply-thread",
      internet_message_id: "<reply-anchor@example.com>",
      received_at:
    )
      @conversation.conversation_messages.create!(
        account: @account,
        invoice: @invoice,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id:,
        internet_message_id:,
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at:,
        from_address: @invoice.customer.email,
        to_addresses: [ @connection.connected_email ],
        reply_to_addresses: [],
        subject: "Question about INV-001",
        matching_status: :matched,
        matching_method: :invoice_reference
      )
    end
end
