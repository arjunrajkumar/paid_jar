class CreateReceivables < ActiveRecord::Migration[8.1]
  def change
    create_table :receivables do |t|
      t.references :account, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true, index: { unique: true }
      t.string :status, null: false, default: "none"
      t.string :payer_segment, null: false, default: "new"
      t.date :due_on
      t.json :outstanding_totals, null: false
      t.json :uncollectible_totals, null: false
      t.integer :open_invoice_count, null: false, default: 0
      t.integer :outstanding_invoice_count, null: false, default: 0
      t.integer :uncollectible_invoice_count, null: false, default: 0
      t.datetime :calculated_at, null: false

      t.timestamps
    end

    add_index :receivables, [ :account_id, :status ]
  end
end
