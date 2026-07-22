class InvoiceScheduleResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :kind, index: true
  attribute :category, index: true
  attribute :day_offset, index: true
  attribute :tone, index: true
  attribute :created_at, form: false
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :invoice_reminders, form: false
  attribute :invoice_reminder_suppressions, form: false

  def self.display_name(record)
    "#{record.kind.humanize}: #{record.key.humanize}"
  end
end
