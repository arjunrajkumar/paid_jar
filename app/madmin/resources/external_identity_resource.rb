class ExternalIdentityResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :provider, form: false, index: true
  attribute :subject, form: false, index: false, searchable: false
  attribute :email_address, form: false, index: true
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :identity, form: false, index: true

  def self.display_name(record)
    "#{record.provider}: #{record.email_address.presence || "identity ##{record.id}"}"
  end
end
