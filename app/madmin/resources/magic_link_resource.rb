class MagicLinkResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :purpose, form: false, index: true
  attribute :expires_at, form: false, index: true
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  # The one-time authentication code is intentionally omitted.
  attribute :identity, form: false, index: true

  member_action do |record|
    button_to "Revoke link",
      revoke_madmin_magic_link_path(record),
      method: :post,
      data: { turbo_confirm: "Revoke this one-time link?" },
      class: "btn btn-danger"
  end

  def self.display_name(record) = "#{record.purpose.humanize} link ##{record.id}"
end
