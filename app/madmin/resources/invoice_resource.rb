class InvoiceResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :number, form: false, index: true
  attribute :status, form: false, index: true
  attribute :provider_status, form: false
  attribute :amount_due, form: false, index: true
  attribute :amount_paid, form: false
  attribute :total, form: false
  attribute :currency, form: false, index: true
  attribute :issued_on, form: false
  attribute :due_on, form: false, index: true
  attribute :paid_on, form: false
  attribute :completed_on, form: false
  attribute :invoice_type, form: false
  attribute :contact_external_id, form: false, searchable: false
  attribute :contact_name, form: false
  attribute :external_id, form: false, searchable: false
  attribute :synced_at, form: false
  attribute :created_at, form: false
  attribute :updated_at, form: false

  # Raw provider records are intentionally omitted from every admin view.
  attribute :account, form: false, index: true
  attribute :invoice_source, form: false
  attribute :customer, form: false, index: true
  attribute :payment_promises, form: false
  attribute :invoice_reminders, form: false
  attribute :invoice_reminder_suppressions, form: false
  attribute :conversation_messages, form: false

  scope :outstanding
  scope :paid
  scope :uncollectible

  member_action do |record|
    button_to "Send manual reminder",
      send_manual_reminder_madmin_invoice_path(record),
      method: :post,
      data: { turbo_confirm: "Queue a manual reminder for this invoice?" },
      class: "btn btn-secondary",
      disabled: !record.outstanding?
  end

  member_action do |record|
    next unless record.outstanding?

    link_to "Record payment promise",
      new_payment_promise_madmin_invoice_path(record),
      class: "btn btn-secondary"
  end

  def self.display_name(record)
    "Invoice #{record.number.presence || record.external_id}"
  end
end
