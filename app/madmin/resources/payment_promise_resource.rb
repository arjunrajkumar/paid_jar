class PaymentPromiseResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :promised_on, form: false, index: true
  attribute :follow_up_on, form: false, index: true
  attribute :status, form: false, index: true
  attribute :active_invoice_id, form: false, index: false
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :invoice, form: false, index: true
  attribute :source_message, form: false
  attribute :follow_up_message, form: false

  scope :status_active

  member_action do |record|
    next unless record.status_active?

    button_to "Mark fulfilled",
      fulfill_madmin_payment_promise_path(record),
      method: :post,
      data: { turbo_confirm: "Mark this promise fulfilled?" },
      class: "btn btn-secondary"
  end

  member_action do |record|
    next unless record.status_active?

    button_to "Cancel promise",
      cancel_madmin_payment_promise_path(record),
      method: :post,
      data: { turbo_confirm: "Cancel this payment promise?" },
      class: "btn btn-danger"
  end

  member_action do |record|
    next unless record.status_active?

    button_to "Run follow-up check",
      enqueue_follow_up_madmin_payment_promise_path(record),
      method: :post,
      class: "btn btn-secondary"
  end

  def self.display_name(record) = "Promise for #{record.invoice.number || "invoice ##{record.invoice_id}"}"
end
