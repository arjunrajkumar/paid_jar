class AddGmailShadowIngestion < ActiveRecord::Migration[8.1]
  def up
    change_table :email_connections, bulk: true do |t|
      t.string :provider_account_id, collation: "utf8mb4_0900_bin"
      t.integer :credential_generation, null: false, default: 0
      t.string :inbound_cursor, collation: "utf8mb4_0900_bin"
      t.datetime :inbound_enabled_at
      t.datetime :last_inbound_attempted_at
      t.datetime :last_inbound_synced_at
      t.text :last_inbound_error
      t.string :inbound_sync_job_id, collation: "utf8mb4_0900_bin"
      t.datetime :inbound_sync_enqueued_at
    end
    add_index :email_connections,
      %i[provider provider_account_id],
      name: "index_email_connections_on_provider_account"

    change_table :conversation_messages, bulk: true do |t|
      t.bigint :email_connection_id
      t.integer :email_connection_generation
      t.string :provider_account_id, collation: "utf8mb4_0900_bin"
      t.text :internet_message_id
      t.string :internet_message_id_digest,
        limit: 64,
        collation: "utf8mb4_0900_bin"
      t.json :in_reply_to_message_ids
      t.json :reference_message_ids
      t.json :reply_to_addresses
      t.json :bcc_addresses
      t.json :provider_metadata
      t.string :matching_status, null: false, default: "matched"
      t.string :matching_method, null: false, default: "none"
      t.boolean :review_required, null: false, default: false
      t.json :review_reasons
      t.datetime :reviewed_at
      t.boolean :automatic, null: false, default: false
    end
    execute <<~SQL.squish
      UPDATE conversation_messages AS messages
      INNER JOIN email_connections AS connections
        ON connections.id = messages.email_connection_id
      SET messages.email_connection_generation = connections.credential_generation
    SQL
    execute <<~SQL.squish
      UPDATE conversation_messages
      SET in_reply_to_message_ids = JSON_ARRAY(),
          reference_message_ids = JSON_ARRAY(),
          reply_to_addresses = JSON_ARRAY(),
          bcc_addresses = JSON_ARRAY(),
          provider_metadata = JSON_OBJECT(),
          review_reasons = JSON_ARRAY()
    SQL
    %i[
      in_reply_to_message_ids
      reference_message_ids
      reply_to_addresses
      bcc_addresses
      provider_metadata
      review_reasons
    ].each do |column|
      change_column_null :conversation_messages, column, false
    end
    remove_index :conversation_messages,
      name: "index_conversation_messages_on_provider_message"
    remove_index :conversation_messages,
      name: "index_conversation_messages_on_provider_thread"
    add_index :conversation_messages, :email_connection_id
    add_index :conversation_messages,
      %i[account_id provider_account_id provider_message_id],
      unique: true,
      name: "index_conversation_messages_on_provider_message"
    add_index :conversation_messages,
      %i[account_id provider_account_id provider_thread_id],
      name: "index_conversation_messages_on_provider_thread"
    add_index :conversation_messages,
      %i[account_id provider_account_id internet_message_id_digest],
      name: "index_conversation_messages_on_account_rfc_message"
    add_index :conversation_messages,
      %i[account_id review_required reviewed_at received_at],
      name: "index_conversation_messages_for_review"
    add_foreign_key :conversation_messages,
      :email_connections,
      on_delete: :nullify

    create_table :email_message_receipts do |t|
      t.bigint :account_id, null: false
      t.bigint :email_connection_id, null: false
      t.integer :email_connection_generation, null: false, default: 0
      t.bigint :conversation_message_id
      t.string :provider_account_id,
        null: false,
        collation: "utf8mb4_0900_bin"
      t.string :provider_message_id,
        null: false,
        collation: "utf8mb4_0900_bin"
      t.string :provider_thread_id, collation: "utf8mb4_0900_bin"
      t.string :provider_history_id, collation: "utf8mb4_0900_bin"
      t.string :direction
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.string :processing_enqueued_job_id, collation: "utf8mb4_0900_bin"
      t.datetime :processing_enqueued_at
      t.string :processing_job_id, collation: "utf8mb4_0900_bin"
      t.datetime :processing_started_at
      t.datetime :discovered_at, null: false
      t.datetime :processed_at
      t.datetime :next_retry_at
      t.text :last_error
      t.json :metadata, null: false
      t.timestamps

      t.index %i[email_connection_id provider_account_id provider_message_id],
        unique: true,
        name: "index_email_receipts_on_connection_message"
      t.index %i[status next_retry_at id],
        name: "index_email_receipts_for_retry"
      t.index %i[status processing_started_at],
        name: "index_email_receipts_for_stale_processing"
      t.index :conversation_message_id
    end
    change_column_default :email_message_receipts,
      :email_connection_generation,
      from: 0,
      to: nil

    add_foreign_key :email_message_receipts, :accounts
    add_foreign_key :email_message_receipts, :email_connections
    add_foreign_key :email_message_receipts,
      :conversation_messages,
      on_delete: :nullify
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Gmail mailbox-scoped message identifiers cannot safely restore the former account-only indexes"
  end
end
