class CustomerEmailAddressResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :email, index: false, searchable: false
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :customer, form: false, index: true

  def self.display_name(record) = record.email
end
