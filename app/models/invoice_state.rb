class InvoiceState < ApplicationRecord
  belongs_to :invoice
  belongs_to :latest_invoice_event, class_name: "InvoiceEvent", optional: true

  validates :customer_situation, :customer_situation_at, presence: true
  validates :invoice_id, uniqueness: true
  validate :latest_invoice_event_belongs_to_invoice

  private
    def latest_invoice_event_belongs_to_invoice
      return if latest_invoice_event.blank? || invoice.blank?

      unless latest_invoice_event.invoice_id == invoice_id
        errors.add :latest_invoice_event, "must belong to invoice"
      end
    end
end
