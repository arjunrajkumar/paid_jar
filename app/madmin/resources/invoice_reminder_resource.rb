class InvoiceReminderResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :category, form: false, index: true
  attribute :stage_key, form: false, index: true
  attribute :day_offset, form: false
  attribute :tone, form: false, index: true
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :invoice, form: false, index: true
  attribute :invoice_message, form: false
  attribute :invoice_schedule, form: false

  def self.display_name(record) = "#{record.stage_key.humanize} reminder ##{record.id}"
end
