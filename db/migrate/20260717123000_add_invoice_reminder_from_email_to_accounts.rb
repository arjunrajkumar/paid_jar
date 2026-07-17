class AddInvoiceReminderFromEmailToAccounts < ActiveRecord::Migration[8.1]
  def up
    add_column :accounts, :invoice_reminder_from_email, :string
    backfill_existing_senders
  end

  def down
    remove_column :accounts, :invoice_reminder_from_email
  end

  private
    def backfill_existing_senders
      execute <<~SQL.squish
        UPDATE accounts
        SET invoice_reminder_from_email = (
          SELECT identities.email_address
          FROM users
          INNER JOIN identities ON identities.id = users.identity_id
          WHERE users.account_id = accounts.id
            AND users.role = 'owner'
            AND users.active = TRUE
          ORDER BY users.id ASC
          LIMIT 1
        )
        WHERE invoice_reminder_from_email IS NULL
      SQL

      execute <<~SQL.squish
        UPDATE accounts
        SET automatic_invoice_reminders_enabled = FALSE
        WHERE automatic_invoice_reminders_enabled = TRUE
          AND invoice_reminder_from_email IS NULL
      SQL
    end
end
