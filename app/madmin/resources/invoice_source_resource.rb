class InvoiceSourceResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :provider, form: false, index: true
  attribute :status, form: false, index: true
  attribute :external_account_id, form: false, index: true
  attribute :external_account_name, form: false, index: true
  attribute :expires_at, form: false
  attribute :last_synced_at, form: false, index: true
  attribute :last_error, form: false, index: false, searchable: false
  attribute :scopes, form: false
  attribute :created_at, form: false
  attribute :updated_at, form: false

  # Decrypted credentials and provider token payloads are intentionally omitted.
  attribute :account, form: false, index: true
  attribute :customers, form: false
  attribute :invoices, form: false
  attribute :webhook_events, form: false

  scope :active
  scope :error
  scope :disconnected

  member_action do |record|
    button_to "Refresh invoices",
      refresh_madmin_invoice_source_path(record),
      method: :post,
      class: "btn btn-secondary",
      disabled: !record.refreshable?
  end

  member_action do |record|
    next if record.disconnected?

    button_to "Disconnect",
      disconnect_madmin_invoice_source_path(record),
      method: :post,
      data: { turbo_confirm: "Disconnect this #{record.provider.humanize} source?" },
      class: "btn btn-danger"
  end

  def self.display_name(record)
    record.external_account_name.presence || "#{record.provider.humanize} source ##{record.id}"
  end
end
