require "test_helper"

class ConversationMessages::ReconcilePendingDeliveriesJobTest < ActiveJob::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
  end

  test "marks stale outbound pending messages failed without enqueuing another delivery" do
    travel_to Time.zone.local(2026, 7, 22, 12) do
      stale_message = create_message(
        delivery_attempted_at: 2.hours.ago - 1.second,
        delivery_job_id: "stale-delivery"
      )

      assert_no_enqueued_jobs do
        ConversationMessages::ReconcilePendingDeliveriesJob.perform_now
      end

      stale_message.reload
      assert_predicate stale_message, :status_failed?
      assert_equal ConversationMessages::ReconcilePendingDeliveriesJob::FAILURE_REASON,
        stale_message.failure_reason
      assert_equal "stale-delivery", stale_message.delivery_job_id
      assert_nil stale_message.sent_at
    end
  end

  test "reconciles legacy pending messages without delivery ownership" do
    travel_to Time.zone.local(2026, 7, 22, 12) do
      message = create_message(
        delivery_attempted_at: nil,
        delivery_job_id: nil,
        created_at: 3.hours.ago
      )

      ConversationMessages::ReconcilePendingDeliveriesJob.perform_now

      assert_predicate message.reload, :status_failed?
    end
  end

  test "marks a stale manual reply delivery unconfirmed and keeps it duplicate protected" do
    travel_to Time.zone.local(2026, 7, 22, 12) do
      conversation = Conversation.for_invoice!(invoice: @invoice)
      connection = email_connections(:paid_jar_gmail)
      anchor = conversation.conversation_messages.create!(
        account: @invoice.account,
        invoice: @invoice,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "stale-manual-anchor",
        provider_thread_id: "stale-manual-thread",
        internet_message_id: "<stale-manual-anchor@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: 4.hours.ago,
        from_address: @invoice.customer.email,
        matching_status: :matched,
        matching_method: :gmail_thread
      )
      reply = ConversationMessages::ManualReply.enqueue!(
        conversation:,
        reply_to_message: anchor,
        actor_user: users(:arjun),
        body: "A reply whose worker stopped after calling Gmail.",
        idempotency_key: "stale-manual-reply",
        composer_token: composer_token_for(conversation, anchor)
      )
      reply.update!(delivery_attempted_at: 3.hours.ago)
      clear_enqueued_jobs

      ConversationMessages::ReconcilePendingDeliveriesJob.perform_now

      assert_predicate reply.reload, :status_failed?
      assert_predicate reply, :delivery_uncertain?
      assert_equal ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
        reply.failure_reason
      assert_predicate reply.conversation_events
        .kind_conversation_manual_reply_unconfirmed
        .sole,
        :actor_kind_system?
      assert_raises ConversationMessages::ManualReply::StaleComposer do
        ConversationMessages::ManualReply.enqueue!(
          conversation:,
          reply_to_message: anchor,
          actor_user: users(:arjun),
          body: "Do not duplicate it.",
          idempotency_key: "duplicate-stale-manual-reply",
          composer_token: composer_token_for(conversation, anchor)
        )
      end
    end
  end

  test "marks a never-attempted stale manual reply as a definite failure" do
    travel_to Time.zone.local(2026, 7, 22, 12) do
      conversation = Conversation.for_invoice!(invoice: @invoice)
      connection = email_connections(:paid_jar_gmail)
      anchor = conversation.conversation_messages.create!(
        account: @invoice.account,
        invoice: @invoice,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "never-attempted-anchor",
        provider_thread_id: "never-attempted-thread",
        internet_message_id: "<never-attempted-anchor@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: 4.hours.ago,
        from_address: @invoice.customer.email,
        matching_status: :matched,
        matching_method: :gmail_thread
      )
      reply = ConversationMessages::ManualReply.enqueue!(
        conversation:,
        reply_to_message: anchor,
        actor_user: users(:arjun),
        body: "This reply never reached its worker.",
        idempotency_key: "never-attempted-reply",
        composer_token: composer_token_for(conversation, anchor)
      )
      reply.update_column(:created_at, 3.hours.ago)
      clear_enqueued_jobs

      ConversationMessages::ReconcilePendingDeliveriesJob.perform_now

      assert_predicate reply.reload, :status_failed?
      assert_not_predicate reply, :delivery_uncertain?
      assert_equal ConversationMessages::ReconcilePendingDeliveriesJob::FAILURE_REASON,
        reply.failure_reason
      assert_predicate reply.conversation_events
        .kind_conversation_manual_reply_failed
        .sole,
        :actor_kind_system?
      assert_enqueued_with(job: ConversationMessages::ManualReplyJob) do
        ConversationMessages::ManualReply.enqueue!(
          conversation:,
          reply_to_message: anchor,
          actor_user: users(:arjun),
          body: "A safe replacement reply.",
          idempotency_key: "replacement-after-never-attempted",
          composer_token: composer_token_for(conversation, anchor)
        )
      end
    end
  end

  test "a later reconciliation repairs missing unconfirmed finalization" do
    travel_to Time.zone.local(2026, 7, 22, 12) do
      conversation = Conversation.for_invoice!(invoice: @invoice)
      connection = email_connections(:paid_jar_gmail)
      anchor = conversation.conversation_messages.create!(
        account: @invoice.account,
        invoice: @invoice,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "repair-reconciliation-anchor",
        provider_thread_id: "repair-reconciliation-thread",
        internet_message_id: "<repair-reconciliation-anchor@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: 4.hours.ago,
        from_address: @invoice.customer.email,
        matching_status: :matched,
        matching_method: :gmail_thread
      )
      reply = ConversationMessages::ManualReply.enqueue!(
        conversation:,
        reply_to_message: anchor,
        actor_user: users(:arjun),
        body: "Finalize this without resending.",
        idempotency_key: "repair-reconciliation",
        composer_token: composer_token_for(conversation, anchor)
      )
      reply.update!(delivery_attempted_at: 3.hours.ago)
      clear_enqueued_jobs
      ConversationEvent.stubs(:record_once!).raises(
        RuntimeError,
        "event store unavailable"
      )

      assert_raises RuntimeError do
        ConversationMessages::ReconcilePendingDeliveriesJob.perform_now
      end

      assert_predicate reply.reload, :status_failed?
      assert_predicate reply, :delivery_uncertain?
      assert_empty reply.conversation_events
        .kind_conversation_manual_reply_unconfirmed
      ConversationEvent.unstub(:record_once!)

      ConversationMessages::ReconcilePendingDeliveriesJob.perform_now

      assert_predicate reply.conversation_events
        .kind_conversation_manual_reply_unconfirmed
        .sole,
        :actor_kind_system?
      assert_equal anchor.received_at,
        conversation.reload.attention_required_at
    end
  end

  test "deserializes and performs a job queued with the former class name" do
    travel_to Time.zone.local(2026, 7, 22, 12) do
      stale_message = create_message(
        delivery_attempted_at: 3.hours.ago,
        delivery_job_id: "serialized-before-rename"
      )
      serialized_job = ConversationMessages::ReconcilePendingDeliveriesJob.new.serialize.merge(
        "job_class" => "InvoiceMessages::ReconcilePendingDeliveriesJob"
      )

      job = ActiveJob::Base.deserialize(serialized_job)

      assert_instance_of InvoiceMessages::ReconcilePendingDeliveriesJob, job
      assert_no_enqueued_jobs { job.perform_now }
      assert_predicate stale_message.reload, :status_failed?
      assert_equal ConversationMessages::ReconcilePendingDeliveriesJob::FAILURE_REASON,
        stale_message.failure_reason
    end
  end

  test "resolves the linked payment promise when its stale follow-up is reconciled" do
    travel_to Time.zone.local(2026, 7, 22, 12) do
      promise = create_payment_promise
      message = create_message(
        kind: :promise_follow_up,
        delivery_attempted_at: 3.hours.ago,
        delivery_job_id: "crashed-promise-follow-up"
      )
      promise.update!(follow_up_message: message)

      ConversationMessages::ReconcilePendingDeliveriesJob.perform_now

      assert_predicate message.reload, :status_failed?
      assert_predicate promise.reload, :status_follow_up_failed?
      assert_nil promise.active_invoice_id
    end
  end

  test "preserves messages that are not stale outbound pending deliveries" do
    travel_to Time.zone.local(2026, 7, 22, 12) do
      boundary = create_message(delivery_attempted_at: 2.hours.ago)
      young = create_message(delivery_attempted_at: 30.minutes.ago)
      not_attempted = create_message(delivery_attempted_at: nil)
      sent = create_message(
        status: :sent,
        delivery_attempted_at: 3.hours.ago,
        sent_at: 3.hours.ago,
        provider_message_id: "provider-sent"
      )
      received = create_message(
        direction: :inbound,
        kind: :customer_reply,
        status: :received,
        delivery_attempted_at: 3.hours.ago,
        received_at: 3.hours.ago
      )

      ConversationMessages::ReconcilePendingDeliveriesJob.perform_now

      assert_predicate boundary.reload, :status_pending?
      assert_predicate young.reload, :status_pending?
      assert_predicate not_attempted.reload, :status_pending?
      assert_predicate sent.reload, :status_sent?
      assert_equal "provider-sent", sent.provider_message_id
      assert_predicate received.reload, :status_received?
    end
  end

  private
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

    def create_message(attributes = {})
      ConversationMessage.create!(
        {
          account: @invoice.account,
          conversation: Conversation.for_invoice!(invoice: @invoice),
          invoice: @invoice,
          direction: :outbound,
          kind: :scheduled_reminder,
          status: :pending,
          delivery_attempted_at: Time.current,
          from_address: "billing@paymentreminder.example",
          to_addresses: [ "customer@example.com" ],
          cc_addresses: [],
          subject: "Payment reminder",
          body: "Please pay invoice INV-001."
        }.merge(attributes)
      )
    end

    def create_payment_promise
      source_message = @invoice.conversation_messages.create!(
        account: @invoice.account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction: :inbound,
        kind: :customer_reply,
        status: :received,
        received_at: Time.current,
        provider_message_id: "reconciler-promise-source",
        from_address: "customer@example.com",
        to_addresses: [ "billing@paymentreminder.example" ],
        cc_addresses: [],
        subject: "Re: Invoice INV-001",
        body: "I will pay tomorrow."
      )
      PaymentPromise.record!(
        invoice: @invoice,
        source_message:,
        promised_on: Date.current - 1.day
      )
    end
end
