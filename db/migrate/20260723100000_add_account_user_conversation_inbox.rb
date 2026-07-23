class AddAccountUserConversationInbox < ActiveRecord::Migration[8.1]
  def change
    change_table :conversations, bulk: true do |t|
      t.bigint :canonical_conversation_id
      t.datetime :attention_required_at
    end
    add_index :conversations,
      %i[account_id canonical_conversation_id],
      name: "index_conversations_on_account_and_canonical"
    add_index :conversations,
      %i[account_id attention_required_at id],
      name: "index_conversations_for_attention"
    add_foreign_key :conversations,
      :conversations,
      column: :canonical_conversation_id

    change_table :conversation_messages, bulk: true do |t|
      t.bigint :reply_to_message_id
      t.bigint :actor_user_id
      t.bigint :reviewed_by_user_id
      t.string :review_outcome
      t.string :requested_provider_account_id,
        collation: "utf8mb4_0900_bin"
      t.string :requested_provider_thread_id,
        collation: "utf8mb4_0900_bin"
      t.string :idempotency_key,
        collation: "utf8mb4_0900_bin"
      t.boolean :delivery_uncertain, null: false, default: false
    end
    add_index :conversation_messages, :reply_to_message_id
    add_index :conversation_messages, :actor_user_id
    add_index :conversation_messages, :reviewed_by_user_id
    add_index :conversation_messages,
      %i[account_id idempotency_key],
      unique: true,
      name: "index_conversation_messages_on_account_idempotency"
    add_index :conversation_messages,
      %i[
        account_id
        requested_provider_account_id
        requested_provider_thread_id
        status
      ],
      name: "index_conversation_messages_on_requested_thread"
    add_index :conversation_events,
      %i[conversation_message_id kind],
      unique: true,
      name: "index_conversation_events_on_message_and_kind"
    add_foreign_key :conversation_messages,
      :conversation_messages,
      column: :reply_to_message_id
    add_foreign_key :conversation_messages,
      :users,
      column: :actor_user_id,
      on_delete: :nullify
    add_foreign_key :conversation_messages,
      :users,
      column: :reviewed_by_user_id,
      on_delete: :nullify
  end
end
