class InvoiceSources::Webhooks::EventResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :provider, form: false, index: true
  attribute :event_type, form: false, index: true
  attribute :provider_event_id, form: false, index: false
  attribute :resource_type, form: false, index: true
  attribute :resource_id, form: false, index: false
  attribute :status, form: false, index: true
  attribute :occurred_at, form: false, index: true
  attribute :processed_at, form: false, index: true
  attribute :last_error, form: false, index: false, searchable: false
  attribute :created_at, form: false
  attribute :updated_at, form: false

  # Signed webhook payloads are intentionally omitted from every admin view.
  attribute :invoice_source, form: false, index: true

  scope :pending
  scope :failed

  member_action do |record|
    next unless record.failed? || record.pending?

    button_to "Retry processing",
      retry_processing_madmin_invoice_sources_webhooks_event_path(record),
      method: :post,
      class: "btn btn-secondary"
  end

  def self.display_name(record) = "#{record.event_type} event ##{record.id}"
end
