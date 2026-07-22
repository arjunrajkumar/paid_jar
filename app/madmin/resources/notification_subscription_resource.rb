class NotificationSubscriptionResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :event, index: true
  attribute :email, index: true
  attribute :created_at, form: false
  attribute :updated_at, form: false

  attribute :user, form: false, index: true

  def self.display_name(record) = "#{record.event.humanize} for #{record.user.name}"
end
