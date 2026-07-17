class CreateCustomerEmailAddresses < ActiveRecord::Migration[8.1]
  def change
    create_table :customer_email_addresses do |t|
      t.references :customer,
        null: false,
        foreign_key: { on_delete: :cascade }
      t.string :email, null: false
      t.timestamps
    end

    add_index :customer_email_addresses,
      %i[customer_id email],
      unique: true
  end
end
