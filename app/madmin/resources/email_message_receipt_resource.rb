class EmailMessageReceiptResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :status, form: false, index: true
  attribute :direction, form: false, index: true
  attribute :attempts, form: false, index: true
  attribute :provider_account_id, form: false, index: false, searchable: false
  attribute :provider_message_id, form: false, index: false, searchable: false
  attribute :provider_thread_id, form: false, index: false, searchable: false
  attribute :provider_history_id, form: false, index: false, searchable: false
  attribute :email_connection_generation, form: false, index: false, searchable: false
  attribute :processing_enqueued_job_id, form: false, index: false, searchable: false
  attribute :processing_enqueued_at, form: false
  attribute :processing_job_id, form: false, index: false, searchable: false
  attribute :processing_started_at, form: false
  attribute :discovered_at, form: false, index: true
  attribute :processed_at, form: false, index: true
  attribute :next_retry_at, form: false, index: true
  attribute :last_error, form: false, index: false, searchable: false
  attribute :metadata, form: false, index: false
  attribute :created_at, form: false
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :email_connection, form: false, index: true
  attribute :conversation_message, form: false, index: true

  member_action do |record|
    next unless record.status_failed? && record.next_retry_at.nil?

    button_to "Retry processing",
      retry_processing_madmin_email_message_receipt_path(record),
      method: :post,
      class: "btn btn-secondary"
  end

  def self.display_name(record) = "Gmail receipt ##{record.id}"
end
