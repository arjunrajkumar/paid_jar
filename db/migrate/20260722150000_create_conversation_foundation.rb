class CreateConversationFoundation < ActiveRecord::Migration[8.1]
  EMAIL_CONNECTION_INDEX_RENAMES = {
    "index_outbound_email_connections_on_account_id" =>
      "index_email_connections_on_account_id",
    "index_outbound_email_connections_on_provider_and_status" =>
      "index_email_connections_on_provider_and_status"
  }.freeze

  CONVERSATION_MESSAGE_INDEX_RENAMES = {
    "index_invoice_messages_on_provider_message" =>
      "index_conversation_messages_on_provider_message",
    "index_invoice_messages_on_provider_thread" =>
      "index_conversation_messages_on_provider_thread",
    "index_invoice_messages_on_account_id" =>
      "index_conversation_messages_on_account_id",
    "index_invoice_messages_on_delivery_job_id" =>
      "index_conversation_messages_on_delivery_job_id",
    "index_invoice_messages_on_outbound_delivery" =>
      "index_conversation_messages_on_outbound_delivery",
    "index_invoice_messages_on_invoice_id" =>
      "index_conversation_messages_on_invoice_id",
    "index_invoice_messages_on_pending_delivery_age" =>
      "index_conversation_messages_on_pending_delivery_age"
  }.freeze

  REMINDER_MESSAGE_INDEX_RENAMES = {
    "index_invoice_reminders_on_invoice_message_id" =>
      "index_invoice_reminders_on_conversation_message_id"
  }.freeze

  def up
    rename_transport_tables_and_columns
    create_conversations
    add_conversation_to_conversation_messages
    backfill_conversations
    attach_conversation_messages
    verify_all_conversation_messages_are_attached!

    change_column_null :conversation_messages, :conversation_id, false
    change_column_null :conversation_messages, :invoice_id, true

    create_conversation_events
  end

  def down
    ensure_all_conversation_messages_have_invoices!

    drop_table :conversation_events
    change_column_null :conversation_messages, :invoice_id, false
    remove_foreign_key :conversation_messages, :conversations
    remove_index :conversation_messages,
      name: "index_conversation_messages_on_conversation_created_at_id"
    remove_column :conversation_messages, :conversation_id
    drop_table :conversations

    restore_legacy_transport_names
  end

  private
    def rename_transport_tables_and_columns
      remove_legacy_message_foreign_keys

      rename_table :outbound_email_connections, :email_connections
      normalize_index_names(
        :email_connections,
        EMAIL_CONNECTION_INDEX_RENAMES
      )

      rename_table :invoice_messages, :conversation_messages
      normalize_index_names(
        :conversation_messages,
        CONVERSATION_MESSAGE_INDEX_RENAMES
      )

      rename_column :invoice_reminders,
        :invoice_message_id,
        :conversation_message_id
      normalize_index_names(
        :invoice_reminders,
        REMINDER_MESSAGE_INDEX_RENAMES
      )

      add_transport_neutral_message_foreign_keys
    end

    def restore_legacy_transport_names
      remove_transport_neutral_message_foreign_keys

      rename_column :invoice_reminders,
        :conversation_message_id,
        :invoice_message_id
      normalize_index_names(
        :invoice_reminders,
        REMINDER_MESSAGE_INDEX_RENAMES.invert
      )

      rename_table :conversation_messages, :invoice_messages
      normalize_index_names(
        :invoice_messages,
        CONVERSATION_MESSAGE_INDEX_RENAMES.invert
      )

      rename_table :email_connections, :outbound_email_connections
      normalize_index_names(
        :outbound_email_connections,
        EMAIL_CONNECTION_INDEX_RENAMES.invert
      )

      add_legacy_message_foreign_keys
    end

    def remove_legacy_message_foreign_keys
      remove_foreign_key :invoice_reminders,
        :invoice_messages,
        column: :invoice_message_id
      remove_foreign_key :payment_promises,
        :invoice_messages,
        column: :source_message_id
      remove_foreign_key :payment_promises,
        :invoice_messages,
        column: :follow_up_message_id
    end

    def add_transport_neutral_message_foreign_keys
      add_foreign_key :invoice_reminders,
        :conversation_messages,
        column: :conversation_message_id
      add_foreign_key :payment_promises,
        :conversation_messages,
        column: :source_message_id
      add_foreign_key :payment_promises,
        :conversation_messages,
        column: :follow_up_message_id
    end

    def remove_transport_neutral_message_foreign_keys
      remove_foreign_key :invoice_reminders,
        :conversation_messages,
        column: :conversation_message_id
      remove_foreign_key :payment_promises,
        :conversation_messages,
        column: :source_message_id
      remove_foreign_key :payment_promises,
        :conversation_messages,
        column: :follow_up_message_id
    end

    def add_legacy_message_foreign_keys
      add_foreign_key :invoice_reminders,
        :invoice_messages,
        column: :invoice_message_id
      add_foreign_key :payment_promises,
        :invoice_messages,
        column: :source_message_id
      add_foreign_key :payment_promises,
        :invoice_messages,
        column: :follow_up_message_id
    end

    def normalize_index_names(table_name, index_renames)
      index_renames.each do |current_name, target_name|
        if index_name_exists?(table_name, current_name)
          rename_index table_name, current_name, target_name
        end

        next if !index_name_exists?(table_name, current_name) &&
          index_name_exists?(table_name, target_name)

        raise ActiveRecord::MigrationError,
          "Could not normalize index #{current_name} to #{target_name} on #{table_name}"
      end
    end

    def create_conversations
      create_table :conversations do |t|
        t.bigint :account_id, null: false
        t.bigint :customer_id
        t.bigint :invoice_id
        t.string :status, null: false, default: "open"
        t.datetime :resolved_at
        t.timestamps

        t.index :invoice_id,
          unique: true,
          name: "index_conversations_on_invoice_id"
        t.index %i[account_id status updated_at],
          name: "index_conversations_on_account_status_updated_at"
        t.index %i[customer_id status updated_at],
          name: "index_conversations_on_customer_status_updated_at"
      end

      add_foreign_key :conversations, :accounts
      add_foreign_key :conversations, :customers, on_delete: :nullify
      add_foreign_key :conversations, :invoices
      add_check_constraint :conversations,
        "(status = 'open' AND resolved_at IS NULL) OR " \
          "(status = 'resolved' AND resolved_at IS NOT NULL)",
        name: "conversations_status_and_resolved_at_consistent"
    end

    def add_conversation_to_conversation_messages
      add_column :conversation_messages, :conversation_id, :bigint
      add_index :conversation_messages,
        %i[conversation_id created_at id],
        name: "index_conversation_messages_on_conversation_created_at_id"
      add_foreign_key :conversation_messages, :conversations
    end

    def backfill_conversations
      execute <<~SQL.squish
        INSERT INTO conversations (
          account_id,
          customer_id,
          invoice_id,
          status,
          created_at,
          updated_at
        )
        SELECT
          invoices.account_id,
          invoices.customer_id,
          invoices.id,
          'open',
          CURRENT_TIMESTAMP(6),
          CURRENT_TIMESTAMP(6)
        FROM invoices
        INNER JOIN (
          SELECT DISTINCT invoice_id
          FROM conversation_messages
        ) represented_invoices
          ON represented_invoices.invoice_id = invoices.id
      SQL
    end

    def attach_conversation_messages
      execute <<~SQL.squish
        UPDATE conversation_messages
        INNER JOIN conversations
          ON conversations.invoice_id = conversation_messages.invoice_id
        SET conversation_messages.conversation_id = conversations.id
      SQL
    end

    def verify_all_conversation_messages_are_attached!
      unlinked_message_count = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM conversation_messages
        WHERE conversation_id IS NULL
      SQL

      return if unlinked_message_count.zero?

      raise ActiveRecord::MigrationError,
        "Cannot require conversation message conversations: " \
          "#{unlinked_message_count} messages could not be linked"
    end

    def create_conversation_events
      create_table :conversation_events do |t|
        t.bigint :account_id, null: false
        t.bigint :conversation_id, null: false
        t.bigint :conversation_message_id
        t.bigint :actor_user_id
        t.string :actor_kind, null: false
        t.string :kind, null: false
        t.json :metadata, null: false
        t.datetime :created_at, null: false

        t.index %i[conversation_id created_at id],
          name: "index_conversation_events_on_conversation_created_at_id"
        t.index %i[account_id kind created_at],
          name: "index_conversation_events_on_account_kind_created_at"
        t.index :conversation_message_id,
          name: "index_conversation_events_on_conversation_message_id"
        t.index :actor_user_id,
          name: "index_conversation_events_on_actor_user_id"
      end

      add_foreign_key :conversation_events, :accounts
      add_foreign_key :conversation_events, :conversations
      add_foreign_key :conversation_events,
        :conversation_messages,
        on_delete: :nullify
      add_foreign_key :conversation_events,
        :users,
        column: :actor_user_id,
        on_delete: :nullify
    end

    def ensure_all_conversation_messages_have_invoices!
      invoiceless_message_count = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM conversation_messages
        WHERE invoice_id IS NULL
      SQL

      return if invoiceless_message_count.zero?

      raise ActiveRecord::IrreversibleMigration,
        "Cannot restore conversation_messages.invoice_id to NOT NULL: " \
          "#{invoiceless_message_count} invoice-less messages exist"
    end
end
