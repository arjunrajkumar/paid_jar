class AccountResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :name, index: true
  attribute :external_account_id, form: false, index: true
  attribute :automatic_invoice_reminders_enabled, index: true
  attribute :invoice_reminder_from_email, index: false
  attribute :invoice_reminder_from_name, index: false
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :invoice_sources, form: false
  attribute :stripe_installation_claims, form: false
  attribute :email_connection, form: false
  attribute :customers, form: false
  attribute :invoices, form: false
  attribute :payment_promises, form: false
  attribute :invoice_reminders, form: false
  attribute :invoice_reminder_suppressions, form: false
  attribute :conversation_messages, form: false
  attribute :users, form: false
  attribute :customer_segments, form: false
  attribute :invoice_schedules, form: false

  member_action do |record|
    button_to "Refresh customer segments",
      refresh_customer_segments_madmin_account_path(record),
      method: :post,
      class: "btn btn-secondary"
  end

  member_action do |record|
    button_to "Run reminder scheduling",
      enqueue_invoice_reminders_madmin_account_path(record),
      method: :post,
      data: { turbo_confirm: "Queue any reminders due today for #{record.name}?" },
      class: "btn btn-secondary"
  end

  def self.display_name(record) = "#{record.name} (#{record.external_account_id})"
end
