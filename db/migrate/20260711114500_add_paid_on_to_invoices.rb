class AddPaidOnToInvoices < ActiveRecord::Migration[8.1]
  def change
    add_column :invoices, :paid_on, :date
    add_index :invoices, :paid_on
  end
end
