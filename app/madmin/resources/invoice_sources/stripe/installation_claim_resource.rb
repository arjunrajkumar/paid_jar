class InvoiceSources::Stripe::InstallationClaimResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :stripe_account_id, form: false, index: true
  attribute :stripe_user_id, form: false, index: false, searchable: false
  attribute :livemode, form: false, index: true
  attribute :expires_at, form: false, index: true
  attribute :consumed_at, form: false, index: true
  attribute :created_at, form: false
  attribute :updated_at, form: false

  # Claim digests and their synthetic password accessors are intentionally omitted.
  attribute :account, form: false, index: true

  def self.display_name(record) = "Stripe claim #{record.stripe_account_id}"
end
