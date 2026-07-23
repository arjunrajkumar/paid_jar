require "test_helper"

class Conversations::WorkUnitSnapshotTest < ActiveSupport::TestCase
  test "rejects a token for another account or conversation" do
    conversation = accounts(:paid_jar).conversations.create!
    other_conversation = accounts(:paid_jar).conversations.create!
    other_account = Account.create!(name: "Other work-unit account")
    other_account_conversation = other_account.conversations.create!

    token = Conversations::WorkUnitSnapshot.token_for(conversation:)

    assert_raises Conversations::WorkUnitSnapshot::Stale do
      Conversations::WorkUnitSnapshot.verify!(
        token:,
        conversation: other_conversation
      )
    end
    assert_raises Conversations::WorkUnitSnapshot::Stale do
      Conversations::WorkUnitSnapshot.verify!(
        token:,
        conversation: other_account_conversation
      )
    end
  end

  test "rejects a token when exact visible message membership changes" do
    account = accounts(:paid_jar)
    conversation = account.conversations.create!
    token = Conversations::WorkUnitSnapshot.token_for(conversation:)
    conversation.conversation_messages.create!(
      account:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      matching_status: :unmatched,
      matching_method: :none
    )

    error = assert_raises Conversations::WorkUnitSnapshot::Stale do
      Conversations::WorkUnitSnapshot.verify!(token:, conversation:)
    end

    assert_equal "Conversation changed; refresh and try again.", error.message
  end

  test "returns the verified signed membership payload" do
    account = accounts(:paid_jar)
    conversation = account.conversations.create!
    message = conversation.conversation_messages.create!(
      account:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      matching_status: :unmatched,
      matching_method: :none
    )
    token = Conversations::WorkUnitSnapshot.token_for(conversation:)

    payload = Conversations::WorkUnitSnapshot.verify!(
      token:,
      conversation:
    )

    assert_equal account.id, payload.fetch("account_id")
    assert_equal conversation.id, payload.fetch("conversation_id")
    assert_equal [ message.id ], payload.fetch("message_ids")
  end
end
