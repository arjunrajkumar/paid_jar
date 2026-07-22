class CreateInvoiceMessages < ActiveRecord::Migration[8.1]
  def up
    create_table :invoice_messages do |t|
      t.references :account, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.string :direction, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :sent_at
      t.datetime :received_at
      t.string :provider_message_id, collation: "utf8mb4_0900_bin"
      t.string :provider_thread_id, collation: "utf8mb4_0900_bin"
      t.string :from_address
      t.json :to_addresses, null: false
      t.json :cc_addresses, null: false
      t.text :subject
      t.text :body
      t.text :failure_reason
      t.timestamps
    end

    add_index :invoice_messages,
      %i[invoice_id direction status sent_at],
      name: "index_invoice_messages_on_outbound_delivery"
    add_index :invoice_messages,
      %i[account_id provider_message_id],
      unique: true,
      name: "index_invoice_messages_on_provider_message"
    add_index :invoice_messages,
      %i[account_id provider_thread_id],
      name: "index_invoice_messages_on_provider_thread"

    add_reference :invoice_reminders,
      :invoice_message,
      foreign_key: true,
      index: { unique: true }

    backfill_reminder_messages

    change_column_null :invoice_reminders, :invoice_message_id, false
    remove_column :invoice_reminders, :status, :string
    remove_column :invoice_reminders, :sent_at, :datetime
    remove_column :invoice_reminders, :provider_message_id, :string
    remove_column :invoice_reminders, :failure_reason, :text
  end

  def down
    ensure_legacy_reminder_schema_can_represent_messages!

    add_column :invoice_reminders, :status, :string, null: false, default: "sent"
    add_column :invoice_reminders, :sent_at, :datetime
    add_column :invoice_reminders, :provider_message_id, :string
    add_column :invoice_reminders, :failure_reason, :text

    execute <<~SQL.squish
      UPDATE invoice_reminders
      INNER JOIN invoice_messages
        ON invoice_messages.id = invoice_reminders.invoice_message_id
      SET
        invoice_reminders.status = invoice_messages.status,
        invoice_reminders.sent_at = invoice_messages.sent_at,
        invoice_reminders.provider_message_id = invoice_messages.provider_message_id,
        invoice_reminders.failure_reason = invoice_messages.failure_reason
    SQL

    remove_reference :invoice_reminders, :invoice_message, foreign_key: true, index: true
    drop_table :invoice_messages
  end

  private
    def backfill_reminder_messages
      invalid_statuses = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM invoice_reminders
        WHERE status NOT IN ('sent', 'failed')
      SQL
      raise "Cannot migrate unsupported invoice reminder statuses" if invalid_statuses.positive?

      duplicate_provider_ids = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM (
          SELECT account_id, provider_message_id
          FROM invoice_reminders
          WHERE provider_message_id IS NOT NULL
          GROUP BY account_id, provider_message_id
          HAVING COUNT(*) > 1
        ) duplicate_provider_ids
      SQL
      raise "Cannot migrate duplicate provider message IDs" if duplicate_provider_ids.positive?

      execute <<~SQL.squish
        INSERT INTO invoice_messages (
          id,
          account_id,
          invoice_id,
          direction,
          kind,
          status,
          sent_at,
          received_at,
          provider_message_id,
          provider_thread_id,
          from_address,
          to_addresses,
          cc_addresses,
          subject,
          body,
          failure_reason,
          created_at,
          updated_at
        )
        SELECT
          invoice_reminders.id,
          invoice_reminders.account_id,
          invoice_reminders.invoice_id,
          'outbound',
          'scheduled_reminder',
          invoice_reminders.status,
          invoice_reminders.sent_at,
          NULL,
          invoice_reminders.provider_message_id,
          NULL,
          NULL,
          JSON_ARRAY(),
          JSON_ARRAY(),
          NULL,
          NULL,
          invoice_reminders.failure_reason,
          invoice_reminders.created_at,
          invoice_reminders.updated_at
        FROM invoice_reminders
      SQL

      execute <<~SQL.squish
        UPDATE invoice_reminders
        SET invoice_message_id = id
      SQL

      unlinked_reminders = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM invoice_reminders
        WHERE invoice_message_id IS NULL
      SQL
      raise "Not every invoice reminder received an invoice message" if unlinked_reminders.positive?
    end

    def ensure_legacy_reminder_schema_can_represent_messages!
      unsupported_messages = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM invoice_messages
        LEFT JOIN invoice_reminders
          ON invoice_reminders.invoice_message_id = invoice_messages.id
        WHERE invoice_reminders.id IS NULL
          OR invoice_messages.kind != 'scheduled_reminder'
          OR invoice_messages.status NOT IN ('sent', 'failed')
      SQL

      return if unsupported_messages.zero?

      raise ActiveRecord::IrreversibleMigration,
        "Invoice messages now contain data the legacy reminder schema cannot represent"
    end
end
