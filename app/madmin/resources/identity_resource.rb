class IdentityResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :email_address, form: false, index: true
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :magic_links, form: false
  attribute :sessions, form: false
  attribute :external_identities, form: false
  attribute :users, form: false
  attribute :accounts, form: false

  def self.display_name(record) = record.email_address
end
