class AddAutomaticInvoiceRemindersEnabledToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :automatic_invoice_reminders_enabled, :boolean,
      null: false,
      default: false
  end
end
