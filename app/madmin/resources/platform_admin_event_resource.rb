class PlatformAdminEventResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :actor_email_address, form: false, index: true
  attribute :action, form: false, index: true
  attribute :target_type, form: false, index: true
  attribute :target_id, form: false, index: true
  attribute :metadata, form: false, index: false
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :actor_identity, form: false
  attribute :account, form: false, index: true
  attribute :target, form: false

  def self.default_sort_column = "created_at"
  def self.default_sort_direction = "desc"
  def self.display_name(record) = "#{record.action} ##{record.id}"
end
