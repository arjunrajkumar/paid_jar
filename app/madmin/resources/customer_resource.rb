class CustomerResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :name, form: false, index: true
  attribute :email, form: false, index: false, searchable: false
  attribute :external_id, form: false, index: true
  attribute :details_observed_at, form: false
  attribute :created_at, form: false, index: true
  attribute :updated_at, form: false

  attribute :account, form: false, index: true
  attribute :invoice_source, form: false
  attribute :customer_segment, form: false, index: true
  attribute :invoices, form: false
  attribute :additional_email_addresses, form: false

  member_action do |record|
    button_to "Refresh payer segment",
      refresh_customer_segment_madmin_customer_path(record),
      method: :post,
      class: "btn btn-secondary"
  end

  def self.display_name(record) = record.name
end
