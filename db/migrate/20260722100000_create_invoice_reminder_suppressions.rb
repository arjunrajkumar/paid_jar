class CreateInvoiceReminderSuppressions < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_reminder_suppressions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.references :invoice_schedule, foreign_key: { on_delete: :nullify }
      t.string :category, null: false
      t.integer :day_offset, null: false
      t.string :stage_key, null: false
      t.string :reason, null: false
      t.datetime :suppressed_at, null: false
      t.timestamps
    end

    add_index :invoice_reminder_suppressions,
      %i[invoice_id stage_key],
      unique: true,
      name: "index_reminder_suppressions_on_invoice_and_stage"
    add_index :invoice_reminder_suppressions,
      %i[invoice_id invoice_schedule_id],
      unique: true,
      name: "index_reminder_suppressions_on_invoice_and_schedule"
    add_check_constraint :invoice_reminder_suppressions,
      "day_offset > 0",
      name: "invoice_reminder_suppressions_day_offset_positive"
  end
end
