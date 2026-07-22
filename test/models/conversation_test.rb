require "test_helper"

class ConversationTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
  end

  test "creates the canonical invoice conversation with its account and customer" do
    conversation = nil

    assert_difference [ -> { Conversation.count }, -> { ConversationEvent.count } ], 1 do
      conversation = Conversation.for_invoice!(invoice: @invoice)
    end

    assert_equal @invoice.account, conversation.account
    assert_equal @invoice.customer, conversation.customer
    assert_equal @invoice, conversation.invoice
    assert_predicate conversation, :status_open?
    assert_nil conversation.resolved_at

    creation_event = conversation.conversation_events.sole
    assert_predicate creation_event, :kind_conversation_created?
    assert_predicate creation_event, :actor_kind_system?
    assert_nil creation_event.actor_user
  end

  test "allows account-only unmatched conversations" do
    conversation = Conversation.new(account: @invoice.account)

    assert_predicate conversation, :valid?
  end

  test "allows multiple unmatched conversations without an invoice" do
    conversations = Array.new(2) do
      Conversation.create!(account: @invoice.account)
    end

    assert conversations.all? { |conversation| conversation.invoice_id.nil? }
    assert_equal 2, Conversation.where(id: conversations.map(&:id)).count
  end

  test "rejects customers and invoices from another account" do
    other_invoice = create_invoice_for(account_name: "Other Conversation Account")
    customer_mismatch = Conversation.new(
      account: @invoice.account,
      customer: other_invoice.customer
    )
    invoice_mismatch = Conversation.new(
      account: @invoice.account,
      customer: other_invoice.customer,
      invoice: other_invoice
    )

    assert_not customer_mismatch.valid?
    assert_includes customer_mismatch.errors[:customer], "must belong to the conversation account"
    assert_not invoice_mismatch.valid?
    assert_includes invoice_mismatch.errors[:invoice], "must belong to the conversation account"
  end

  test "requires an invoice-backed conversation to use the invoice customer" do
    other_customer = @invoice.invoice_source.customers.create!(
      account: @invoice.account,
      external_id: SecureRandom.uuid,
      name: "Other Conversation Customer"
    )
    conversation = Conversation.new(
      account: @invoice.account,
      customer: other_customer,
      invoice: @invoice
    )

    assert_not conversation.valid?
    assert_includes conversation.errors[:customer], "must match the conversation invoice customer"
  end

  test "enforces one conversation per invoice in the model and database" do
    Conversation.for_invoice!(invoice: @invoice)
    duplicate = Conversation.new(
      account: @invoice.account,
      customer: @invoice.customer,
      invoice: @invoice
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:invoice_id], "has already been taken"
    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "returns the same canonical conversation repeatedly" do
    first = Conversation.for_invoice!(invoice: @invoice)

    assert_no_difference -> { Conversation.count } do
      assert_equal first, Conversation.for_invoice!(invoice: @invoice)
    end
  end

  test "requires a persisted invoice for canonical lookup" do
    assert_raises ArgumentError do
      Conversation.for_invoice!(invoice: nil)
    end
    assert_raises ArgumentError do
      Conversation.for_invoice!(invoice: @invoice.dup)
    end
  end

  test "groups different provider threads into one logical conversation" do
    conversation = Conversation.for_invoice!(invoice: @invoice)
    first_message = create_sent_message(
      conversation:,
      provider_message_id: "provider-message-one",
      provider_thread_id: "provider-thread-one"
    )
    second_message = create_sent_message(
      conversation:,
      provider_message_id: "provider-message-two",
      provider_thread_id: "provider-thread-two"
    )

    assert_equal conversation, first_message.conversation
    assert_equal conversation, second_message.conversation
    assert_equal %w[provider-thread-one provider-thread-two],
      conversation.conversation_messages.order(:id).pluck(:provider_thread_id)
  end

  test "resolves and reopens idempotently with one event per transition" do
    conversation = Conversation.for_invoice!(invoice: @invoice)
    actor = users(:arjun)
    resolved_at = Time.zone.local(2026, 7, 22, 12)
    reopened_at = Time.zone.local(2026, 7, 22, 13)

    assert_difference -> { conversation.conversation_events.kind_conversation_resolved.count }, 1 do
      conversation.resolve!(actor_user: actor, at: resolved_at)
    end
    assert_predicate conversation, :status_resolved?
    assert_equal resolved_at, conversation.resolved_at
    resolution_event = conversation.conversation_events.kind_conversation_resolved.sole
    assert_equal resolved_at, resolution_event.created_at
    assert_predicate resolution_event, :actor_kind_user?
    assert_equal actor, resolution_event.actor_user

    assert_no_difference -> { conversation.conversation_events.count } do
      conversation.resolve!(actor_user: actor, at: resolved_at + 1.hour)
    end
    assert_equal resolved_at, conversation.reload.resolved_at

    assert_difference -> { conversation.conversation_events.kind_conversation_reopened.count }, 1 do
      conversation.reopen!(at: reopened_at)
    end
    assert_predicate conversation, :status_open?
    assert_nil conversation.resolved_at
    reopening_event = conversation.conversation_events.kind_conversation_reopened.sole
    assert_equal reopened_at, reopening_event.created_at
    assert_predicate reopening_event, :actor_kind_system?

    assert_no_difference -> { conversation.conversation_events.count } do
      conversation.reopen!(at: reopened_at + 1.hour)
    end
  end

  test "requires resolution timestamps to agree with status" do
    open_conversation = Conversation.new(
      account: @invoice.account,
      resolved_at: Time.current
    )
    resolved_conversation = Conversation.new(
      account: @invoice.account,
      status: :resolved
    )

    assert_not open_conversation.valid?
    assert_includes open_conversation.errors[:resolved_at], "must be blank for an open conversation"
    assert_not resolved_conversation.valid?
    assert_includes resolved_conversation.errors[:resolved_at], "must be present for a resolved conversation"
  end

  test "enforces the status and resolution timestamp invariant in the database" do
    conversation = Conversation.create!(account: @invoice.account)

    assert_raises ActiveRecord::StatementInvalid do
      conversation.update_column(:resolved_at, Time.current)
    end
  end

  test "does not destroy messages when independently destroying a conversation" do
    conversation = Conversation.for_invoice!(invoice: @invoice)
    message = create_sent_message(
      conversation:,
      provider_message_id: "retained-provider-message",
      provider_thread_id: "retained-provider-thread"
    )
    event_ids = conversation.conversation_event_ids

    assert_raises ActiveRecord::DeleteRestrictionError do
      conversation.destroy!
    end
    assert_predicate Conversation.where(id: conversation.id), :exists?
    assert_predicate ConversationMessage.where(id: message.id), :exists?
    assert_equal event_ids.sort, ConversationEvent.where(id: event_ids).pluck(:id).sort
  end

  test "nullifies an unmatched conversation when its customer is deleted" do
    customer = @invoice.invoice_source.customers.create!(
      account: @invoice.account,
      external_id: SecureRandom.uuid,
      name: "Unmatched Conversation Customer"
    )
    conversation = Conversation.create!(account: @invoice.account, customer:)

    customer.destroy!

    assert_nil conversation.reload.customer
  end

  private
    def create_sent_message(conversation:, provider_message_id:, provider_thread_id:)
      conversation.conversation_messages.create!(
        account: conversation.account,
        invoice: conversation.invoice,
        direction: :outbound,
        kind: :invoice_resend,
        status: :sent,
        sent_at: Time.current,
        from_address: "billing@paymentreminder.example",
        to_addresses: [ "customer@example.com" ],
        cc_addresses: [],
        subject: "Invoice copy",
        body: "Here is your invoice.",
        provider_message_id:,
        provider_thread_id:
      )
    end

    def create_invoice_for(account_name:)
      account = Account.create!(name: account_name)
      invoice_source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: SecureRandom.uuid
      )
      customer = invoice_source.customers.create!(
        account:,
        external_id: SecureRandom.uuid,
        name: "Conversation Customer"
      )

      invoice_source.invoices.create!(
        account:,
        customer:,
        external_id: SecureRandom.uuid,
        status: :open
      )
    end
end
