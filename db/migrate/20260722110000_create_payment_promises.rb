class CreatePaymentPromises < ActiveRecord::Migration[8.1]
  def change
    create_table :payment_promises do |t|
      t.references :account, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.references :source_message,
        null: false,
        foreign_key: { to_table: :invoice_messages },
        index: { unique: true }
      t.references :follow_up_message,
        null: true,
        foreign_key: { to_table: :invoice_messages },
        index: { unique: true }
      t.bigint :active_invoice_id
      t.date :promised_on, null: false
      t.date :follow_up_on, null: false
      t.string :status, null: false, default: "active"
      t.timestamps
    end

    add_index :payment_promises,
      %i[invoice_id status follow_up_on],
      name: "index_payment_promises_on_invoice_status_and_follow_up"
    add_index :payment_promises,
      :active_invoice_id,
      unique: true
    add_foreign_key :payment_promises,
      :invoices,
      column: :active_invoice_id
  end
end
