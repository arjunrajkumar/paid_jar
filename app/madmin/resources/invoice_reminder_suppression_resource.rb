class InvoiceReminderSuppressionResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :category, form: false
  attribute :day_offset, form: false
  attribute :stage_key, form: false, index: true
  attribute :reason, form: false, index: true
  attribute :suppressed_at, form: false, index: true
  attribute :created_at, form: false
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :invoice, form: false, index: true
  attribute :invoice_schedule, form: false

  def self.display_name(record) = "#{record.stage_key.humanize} suppression ##{record.id}"
end
