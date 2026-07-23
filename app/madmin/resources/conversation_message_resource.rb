class ConversationMessageResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :direction, form: false, index: true
  attribute :kind, form: false, index: true
  attribute :status, form: false, index: true
  attribute :sent_at, form: false, index: true
  attribute :received_at, form: false, index: true
  attribute :provider_message_id, form: false, index: false, searchable: false
  attribute :provider_thread_id, form: false, index: false, searchable: false
  attribute :email_connection_generation, form: false, index: false, searchable: false
  attribute :internet_message_id, form: false, index: false, searchable: false
  attribute :in_reply_to_message_ids, form: false, index: false
  attribute :reference_message_ids, form: false, index: false
  attribute :reply_to_addresses, form: false, index: false
  attribute :provider_metadata, form: false, index: false
  attribute :matching_status, form: false, index: true
  attribute :matching_method, form: false, index: true
  attribute :review_required, form: false, index: true
  attribute :review_reasons, form: false, index: false
  attribute :reviewed_at, form: false, index: true
  attribute :automatic, form: false, index: true
  attribute :from_address, form: false, index: false, searchable: false
  attribute :to_addresses, form: false, index: false
  attribute :cc_addresses, form: false, index: false
  attribute :bcc_addresses, form: false, index: false
  attribute :subject, form: false, index: false, searchable: false
  attribute :body, form: false, index: false, searchable: false
  attribute :failure_reason, form: false, index: false, searchable: false
  attribute :delivery_job_id, form: false, index: false, searchable: false
  attribute :delivery_attempted_at, form: false, index: false
  attribute :created_at, form: false
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :email_connection, form: false, index: true
  attribute :email_message_receipt, form: false
  attribute :invoice, form: false, index: true
  attribute :invoice_reminder, form: false
  attribute :payment_promise, form: false
  attribute :payment_promise_follow_up, form: false

  scope :successful_outbound

  def self.display_name(record) = "#{record.kind.humanize} message ##{record.id}"
end
