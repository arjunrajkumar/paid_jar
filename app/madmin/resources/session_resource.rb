class SessionResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :ip_address, form: false, index: false, searchable: false
  attribute :user_agent, form: false, index: false, searchable: false
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :identity, form: false, index: true

  member_action do |record|
    button_to "Revoke session",
      revoke_madmin_session_path(record),
      method: :post,
      data: { turbo_confirm: "Revoke this signed-in session?" },
      class: "btn btn-danger"
  end

  def self.display_name(record) = "Session ##{record.id}"
end
