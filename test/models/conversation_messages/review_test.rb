require "test_helper"

class ConversationMessages::ReviewTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @actor = users(:arjun)
    @connection = email_connections(:paid_jar_gmail)
    @conversation = @account.conversations.create!(
      attention_required_at: Time.zone.local(2026, 7, 22, 11)
    )
  end

  test "completes one logical Gmail-thread review work item with immutable evidence" do
    first = create_review_message("review-one", received_at: Time.zone.local(2026, 7, 22, 10))
    second = create_review_message("review-two", received_at: Time.zone.local(2026, 7, 22, 11))

    ConversationMessages::Review.complete!(
      conversation: @conversation,
      message: first,
      actor_user: @actor,
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(@conversation),
      at: Time.zone.local(2026, 7, 23, 9)
    )

    [ first, second ].each do |message|
      message.reload
      assert_equal Time.zone.local(2026, 7, 23, 9), message.reviewed_at
      assert_equal @actor, message.reviewed_by_user
      assert_equal "unmatched", message.matching_status
      assert_equal "none", message.matching_method
      assert_equal [ "automatic_response" ], message.review_reasons
    end
    assert_nil @conversation.reload.attention_required_at
    assert_equal 2,
      @conversation.conversation_events.kind_conversation_message_reviewed.count
  end

  test "does not clear attention raised after the reviewed thread work" do
    message = create_review_message("older-review", received_at: Time.zone.local(2026, 7, 22, 10))
    @conversation.update!(attention_required_at: Time.zone.local(2026, 7, 22, 12))

    ConversationMessages::Review.complete!(
      conversation: @conversation,
      message:,
      actor_user: @actor,
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(@conversation)
    )

    assert_equal Time.zone.local(2026, 7, 22, 12),
      @conversation.reload.attention_required_at
  end

  test "reviews one mailbox thread across separate unlinked conversations" do
    other_conversation = @account.conversations.create!(
      attention_required_at: Time.zone.local(2026, 7, 22, 12)
    )
    first = create_review_message("review-across-one", received_at: Time.zone.local(2026, 7, 22, 10))
    second = create_review_message(
      "review-across-two",
      received_at: Time.zone.local(2026, 7, 22, 12),
      conversation: other_conversation
    )
    @conversation.update!(attention_required_at: first.received_at)

    covered = ConversationMessages::Review.complete!(
      conversation: @conversation,
      message: first,
      actor_user: @actor,
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(@conversation)
    )

    assert_equal [ first.id, second.id ], covered.map(&:id)
    assert first.reload.reviewed_at
    assert second.reload.reviewed_at
    assert_nil @conversation.reload.attention_required_at
    assert_nil other_conversation.reload.attention_required_at
  end

  test "a later message remains visible and reviewable after its thread was reviewed" do
    first = create_review_message(
      "review-before-later-message",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    ConversationMessages::Review.complete!(
      conversation: @conversation,
      message: first,
      actor_user: @actor,
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(@conversation)
    )
    later_conversation = @account.conversations.create!(
      attention_required_at: Time.zone.local(2026, 7, 22, 12)
    )
    later = create_review_message(
      "review-later-message",
      received_at: Time.zone.local(2026, 7, 22, 12),
      conversation: later_conversation
    )

    detail = Conversations::Detail.call(conversation: @conversation)

    assert_includes detail.timeline.messages, later
    assert_predicate later, :awaiting_review?
    ConversationMessages::Review.complete!(
      conversation: @conversation,
      message: later,
      actor_user: @actor,
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(@conversation)
    )
    assert_not_predicate later.reload, :awaiting_review?
    assert_predicate later, :review_outcome_no_match_needed?
  end

  private
    def create_review_message(provider_message_id, received_at:, conversation: @conversation)
      conversation.conversation_messages.create!(
        account: @account,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "review-thread",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at:,
        from_address: "automatic@example.com",
        matching_status: :unmatched,
        matching_method: :none,
        review_required: true,
        review_reasons: [ "automatic_response" ],
        automatic: true
      )
    end
end
