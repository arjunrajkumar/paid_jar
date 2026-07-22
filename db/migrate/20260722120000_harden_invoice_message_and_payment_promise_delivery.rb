class HardenInvoiceMessageAndPaymentPromiseDelivery < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE invoice_messages
      SET sent_at = created_at
      WHERE direction = 'outbound'
        AND status = 'sent'
        AND sent_at IS NULL
    SQL

    add_index :payment_promises,
      %i[status follow_up_on],
      name: "index_payment_promises_on_due_follow_up"
    add_check_constraint :payment_promises,
      <<~SQL.squish,
        (
          status = 'active'
          AND active_invoice_id IS NOT NULL
          AND active_invoice_id = invoice_id
        ) OR (
          status <> 'active'
          AND active_invoice_id IS NULL
        )
      SQL
      name: "payment_promises_active_invoice_matches_status"
  end

  def down
    remove_check_constraint :payment_promises,
      name: "payment_promises_active_invoice_matches_status"
    remove_index :payment_promises,
      name: "index_payment_promises_on_due_follow_up"
  end
end
