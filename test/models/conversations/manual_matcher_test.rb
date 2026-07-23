require "test_helper"

class Conversations::ManualMatcherTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @actor = users(:arjun)
    @connection = email_connections(:paid_jar_gmail)
  end

  test "links every source in a Gmail thread to the invoice canonical conversation" do
    target = Conversation.for_invoice!(invoice: @invoice)
    source_one = create_source_conversation
    source_two = create_source_conversation
    first = create_review_message(source_one, provider_message_id: "manual-match-one")
    second = create_review_message(source_two, provider_message_id: "manual-match-two")
    source_one.update!(attention_required_at: first.received_at)
    source_two.update!(attention_required_at: second.received_at)

    result = Conversations::ManualMatcher.call(
      source_conversation: source_one,
      reviewed_message: first,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source_one),
      at: Time.zone.local(2026, 7, 23, 9)
    )

    assert_equal target, result
    assert_equal target, source_one.reload.canonical_conversation
    assert_equal target, source_two.reload.canonical_conversation
    assert_equal [ @invoice.id ], [ first.reload.invoice_id, second.reload.invoice_id ].uniq
    assert first.reviewed_at
    assert second.reviewed_at
    assert_equal @actor, first.reviewed_by_user
    assert_equal @actor, second.reviewed_by_user
    assert_equal second.received_at, target.reload.attention_required_at
    assert_nil source_one.attention_required_at
    assert_nil source_two.attention_required_at

    event = target.conversation_events.kind_conversation_manually_matched.sole
    assert_predicate event, :actor_kind_user?
    assert_equal @actor, event.actor_user
    assert_equal [ source_one.id, source_two.id ].sort, event.metadata.fetch("source_conversation_ids").sort
    assert_equal [ first.id, second.id ].sort, event.metadata.fetch("covered_message_ids").sort
  end

  test "same-target replay is idempotent and a different target is rejected" do
    source = create_source_conversation
    message = create_review_message(source, provider_message_id: "manual-match-replay")
    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )

    assert_no_difference -> { ConversationEvent.count } do
      assert_equal target, Conversations::ManualMatcher.call(
        source_conversation: source,
        reviewed_message: message,
        target_invoice: @invoice,
        actor_user: @actor,
        work_unit_token: conversation_work_unit_token(source.reload)
      )
    end

    other_invoice = @invoice.dup
    other_invoice.external_id = "other-match-target"
    other_invoice.number = "INV-OTHER"
    other_invoice.save!

    assert_no_difference [ -> { Conversation.count }, -> { ConversationEvent.count } ] do
      assert_raises Conversations::ManualMatcher::AlreadyLinked do
        Conversations::ManualMatcher.call(
          source_conversation: source,
          reviewed_message: message,
          target_invoice: other_invoice,
          actor_user: @actor,
          work_unit_token: conversation_work_unit_token(source.reload)
        )
      end
    end
    assert_equal target, source.reload.canonical_conversation
  end

  test "reloads a locked invoice before deriving the canonical customer" do
    stale_invoice = Invoice.find(@invoice.id)
    replacement_customer = @invoice.invoice_source.customers.create!(
      account: @account,
      external_id: "manual-match-replacement-customer",
      name: "Replacement invoice customer",
      email: "replacement-invoice-customer@example.com"
    )
    @invoice.update!(customer: replacement_customer)
    source = create_source_conversation
    message = create_review_message(source, provider_message_id: "stale-invoice-customer")

    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: stale_invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )

    assert_equal replacement_customer, target.customer
    assert_equal replacement_customer, target.invoice.customer
    assert_equal target, source.reload.canonical_conversation
    assert_predicate message.reload, :valid?
  end

  test "same-target replay stays idempotent when the thread includes clean messages" do
    source = create_source_conversation
    review_message = create_review_message(source, provider_message_id: "mixed-review-message")
    clean_message = create_clean_message(source, provider_message_id: "mixed-clean-message")
    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: review_message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )
    event_count = ConversationEvent.count

    assert_equal target, Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: review_message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )

    assert_equal event_count, ConversationEvent.count
    assert_equal @invoice, review_message.reload.invoice
    assert_equal @invoice, clean_message.reload.invoice
    assert review_message.reviewed_at
    assert_nil clean_message.reviewed_at
  end

  test "rejects an invoice whose customer contradicts the source customer" do
    other_customer = @invoice.invoice_source.customers.create!(
      account: @account,
      external_id: "manual-match-other-customer",
      name: "Other manual-match customer",
      email: "other-manual-match@example.com"
    )
    source = @account.conversations.create!(customer: other_customer)
    message = create_review_message(source, provider_message_id: "customer-conflict")

    error = assert_raises Conversations::ManualMatcher::InvalidSelection do
      Conversations::ManualMatcher.call(
        source_conversation: source,
        reviewed_message: message,
        target_invoice: @invoice,
        actor_user: @actor,
        work_unit_token: conversation_work_unit_token(source)
      )
    end

    assert_equal "This thread is already assigned to another customer.", error.message
    assert_nil source.reload.canonical_conversation
    assert_equal other_customer, source.customer
    assert_nil message.reload.invoice
  end

  test "supports audited customer-only assignment without inventing an invoice conversation" do
    source = create_source_conversation
    message = create_review_message(source, provider_message_id: "customer-only-match")

    result = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_customer: @invoice.customer,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )

    assert_equal source, result
    assert_equal @invoice.customer, source.reload.customer
    assert_nil source.canonical_conversation
    assert_nil message.reload.invoice
    assert message.reviewed_at
    assert_equal @actor, message.reviewed_by_user
    assert_predicate source.conversation_events.kind_conversation_manually_matched.sole,
      :actor_kind_user?
  end

  test "corrects a no-match review to an audited idempotent manual match" do
    source = create_source_conversation
    message = create_review_message(
      source,
      provider_message_id: "corrected-manual-match"
    )
    source.update!(attention_required_at: message.received_at)
    ConversationMessages::Review.complete!(
      conversation: source,
      message:,
      actor_user: @actor,
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(source)
    )
    assert_predicate message.reload, :review_outcome_no_match_needed?
    assert_nil source.reload.attention_required_at

    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )

    assert_predicate message.reload, :review_outcome_manual_match?
    assert_predicate message, :trusted_matching_anchor?
    assert_equal message.received_at, target.reload.attention_required_at
    correction = message.conversation_events
      .kind_conversation_message_review_corrected
      .sole
    assert_equal "no_match_needed", correction.metadata.fetch("previous_outcome")
    assert_equal "manual_match", correction.metadata.fetch("outcome")
    event_count = ConversationEvent.count

    assert_equal target, Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )
    assert_equal event_count, ConversationEvent.count
  end

  private
    def create_source_conversation
      @account.conversations.create!
    end

    def create_review_message(conversation, provider_message_id:)
      conversation.conversation_messages.create!(
        account: @account,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "manual-match-thread",
        internet_message_id: "<#{provider_message_id}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.zone.local(2026, 7, 22, provider_message_id.end_with?("two") ? 11 : 10),
        from_address: @invoice.customer.email,
        matching_status: :unmatched,
        matching_method: :none,
        review_required: true,
        review_reasons: [ "invoice_unmatched" ]
      )
    end

    def create_clean_message(conversation, provider_message_id:)
      conversation.conversation_messages.create!(
        account: @account,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "manual-match-thread",
        internet_message_id: "<#{provider_message_id}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.zone.local(2026, 7, 22, 12),
        from_address: @invoice.customer.email,
        matching_status: :matched,
        matching_method: :customer_only,
        review_required: false
      )
    end
end
