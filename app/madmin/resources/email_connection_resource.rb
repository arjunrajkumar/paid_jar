class EmailConnectionResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :provider, form: false, index: true
  attribute :status, form: false, index: true
  attribute :connected_email, form: false, index: false, searchable: false
  attribute :provider_display_name, form: false, index: true
  attribute :token_expires_at, form: false
  attribute :scopes, form: false
  attribute :last_error, form: false, index: false, searchable: false
  attribute :created_at, form: false
  attribute :updated_at, form: false

  # Decrypted OAuth credentials are intentionally omitted.
  attribute :account, form: false, index: true

  member_action do |record|
    next if record.disconnected?

    button_to "Disconnect Gmail",
      disconnect_madmin_email_connection_path(record),
      method: :post,
      data: { turbo_confirm: "Disconnect Gmail and disable automatic reminders?" },
      class: "btn btn-danger"
  end

  def self.display_name(record)
    record.provider_display_name.presence || "#{record.provider.humanize} for #{record.account.name}"
  end
end
