require "test_helper"

class ConversationEventTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
  end

  test "records required fields and gives each event independent metadata" do
    event = ConversationEvent.record!(
      conversation: @conversation,
      kind: :conversation_resolved,
      actor_kind: :system
    )
    first = ConversationEvent.new
    second = ConversationEvent.new

    assert_equal @conversation.account, event.account
    assert_equal({}, event.metadata)
    assert_predicate event, :kind_conversation_resolved?
    assert_predicate event, :actor_kind_system?

    first.metadata["source"] = "first"
    assert_equal({}, second.metadata)

    missing_fields = ConversationEvent.new(metadata: nil)
    assert_not missing_fields.valid?
    assert_includes missing_fields.errors[:account], "must exist"
    assert_includes missing_fields.errors[:conversation], "must exist"
    assert_includes missing_fields.errors[:actor_kind], "is not included in the list"
    assert_includes missing_fields.errors[:kind], "is not included in the list"
    assert_includes missing_fields.errors[:metadata], "can't be blank"
  end

  test "derives the event account from its conversation" do
    arbitrary_account = Account.create!(name: "Arbitrary Event Account")
    event = ConversationEvent.new(
      account: arbitrary_account,
      conversation: @conversation,
      kind: :conversation_resolved,
      actor_kind: :system
    )

    assert_predicate event, :valid?
    assert_equal @conversation.account, event.account
    event.save!
    assert_equal @conversation.account_id, event.reload.account_id
  end

  test "requires an attached message to share the account and conversation" do
    other_invoice = @invoice.dup
    other_invoice.external_id = SecureRandom.uuid
    other_invoice.number = "INV-EVENT-OTHER"
    other_invoice.save!
    other_conversation = Conversation.for_invoice!(invoice: other_invoice)
    other_message = create_received_message(conversation: other_conversation)
    event = ConversationEvent.new(
      conversation: @conversation,
      conversation_message: other_message,
      kind: :conversation_resolved,
      actor_kind: :system
    )

    assert_not event.valid?
    assert_includes event.errors[:conversation_message], "must belong to the same account and conversation"
  end

  test "requires user events to identify a user from the conversation account" do
    user_event = ConversationEvent.new(
      conversation: @conversation,
      kind: :conversation_resolved,
      actor_kind: :user
    )
    other_account = Account.create!(name: "Other Actor Account")
    other_user = other_account.users.create!(name: "Other Actor")
    cross_account_event = ConversationEvent.new(
      conversation: @conversation,
      kind: :conversation_resolved,
      actor_kind: :user,
      actor_user: other_user
    )

    assert_not user_event.valid?
    assert_includes user_event.errors[:actor_user], "must be present for a user event"
    assert_not cross_account_event.valid?
    assert_includes cross_account_event.errors[:actor_user], "must belong to the conversation account"
  end

  test "system and AI events cannot claim a user actor" do
    %i[system ai].each do |actor_kind|
      event = ConversationEvent.new(
        conversation: @conversation,
        kind: :conversation_resolved,
        actor_kind:,
        actor_user: users(:arjun)
      )

      assert_not event.valid?
      assert_includes event.errors[:actor_user], "must be blank for a system or AI event"
    end
  end

  test "orders events chronologically by created at and id" do
    timestamp = Time.zone.local(2026, 7, 22, 12)
    later = create_event(created_at: timestamp + 1.minute, kind: :conversation_resolved)
    first_at_timestamp = create_event(created_at: timestamp, kind: :conversation_reopened)
    second_at_timestamp = create_event(created_at: timestamp, kind: :conversation_resolved)

    ordered = ConversationEvent
      .where(id: [ later.id, first_at_timestamp.id, second_at_timestamp.id ])
      .chronological

    assert_equal [ first_at_timestamp, second_at_timestamp, later ], ordered
  end

  test "rejects updates and individual destruction after persistence" do
    event = @conversation.conversation_events.kind_conversation_created.sole

    assert_raises ActiveRecord::ReadOnlyRecord do
      event.update!(metadata: { "changed" => true })
    end
    assert_raises ActiveRecord::ReadOnlyRecord do
      event.destroy!
    end
    assert_raises ActiveRecord::ReadOnlyRecord do
      event.delete
    end

    assert_equal({}, event.reload.metadata)
  end

  test "recording an event has no invoice promise message reminder or delivery side effects" do
    invoice_attributes = @invoice.attributes

    assert_no_difference [
      -> { Invoice.count },
      -> { PaymentPromise.count },
      -> { ConversationMessage.count },
      -> { InvoiceReminder.count }
    ] do
      ConversationEvent.record!(
        conversation: @conversation,
        kind: :conversation_resolved,
        actor_kind: :system,
        metadata: { "reason" => "audit-only" }
      )
    end

    assert_equal invoice_attributes, @invoice.reload.attributes
  end

  private
    def create_event(created_at:, kind:)
      ConversationEvent.create!(
        conversation: @conversation,
        kind:,
        actor_kind: :system,
        created_at:
      )
    end

    def create_received_message(conversation:)
      conversation.conversation_messages.create!(
        account: conversation.account,
        invoice: conversation.invoice,
        direction: :inbound,
        kind: :customer_reply,
        status: :received,
        received_at: Time.current,
        from_address: "customer@example.com",
        to_addresses: [ "billing@paymentreminder.example" ],
        cc_addresses: [],
        subject: "Re: Invoice",
        body: "I will pay shortly."
      )
    end
end
