class CustomerSegmentResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :payer_segment, form: false, index: true
  attribute :on_time_rate, index: true
  attribute :created_at, form: false
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :customers, form: false

  def self.display_name(record)
    "#{record.account.name} / #{record.payer_segment.humanize}"
  end
end
