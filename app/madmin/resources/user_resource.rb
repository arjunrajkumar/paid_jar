class UserResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :name, index: true
  attribute :role, form: false, index: true
  attribute :active, form: false, index: true
  attribute :verified_at, form: false, index: true
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :identity, form: false
  attribute :notification_subscriptions, form: false

  member_action do |record|
    next if record.system?

    button_to "Act as this user",
      impersonate_madmin_user_path(record),
      method: :post,
      data: { turbo_confirm: "Act as #{record.name} in #{record.account.name}?" },
      class: "btn btn-secondary",
      disabled: !record.active?
  end

  member_action do |record|
    next if record.system?

    if record.active?
      button_to "Suspend access",
        suspend_madmin_user_path(record),
        method: :post,
        data: { turbo_confirm: "Suspend access for #{record.name}?" },
        class: "btn btn-danger"
    else
      button_to "Restore access",
        reactivate_madmin_user_path(record),
        method: :post,
        data: { turbo_confirm: "Restore access for #{record.name}?" },
        class: "btn btn-secondary",
        disabled: record.identity.blank?
    end
  end

  member_action do |record|
    next if record.system?

    form_with url: change_role_madmin_user_path(record), method: :post do
      safe_join(
        [
          select_tag(:role, options_for_select(%w[owner admin member].map { |role| [ role.humanize, role ] }, record.role)),
          submit_tag("Change role", class: "btn btn-secondary")
        ]
      )
    end
  end

  scope :active
  scope :admin

  def self.display_name(record) = "#{record.name} (#{record.account.name})"
end
