class AddDeliveryOwnershipToInvoiceMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :invoice_messages,
      :delivery_job_id,
      :string,
      collation: "utf8mb4_0900_bin"
    add_column :invoice_messages, :delivery_attempted_at, :datetime
    add_index :invoice_messages, :delivery_job_id
    add_index :invoice_messages,
      %i[status delivery_attempted_at],
      name: "index_invoice_messages_on_pending_delivery_age"
  end
end
