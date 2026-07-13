class Invoice < ApplicationRecord
  belongs_to :account, inverse_of: :invoices
  belongs_to :invoice_source, inverse_of: :invoices
  attribute :provider_data, default: -> { {} }
  attribute :raw_data, default: -> { {} }

  validates :external_id, presence: true
  validates :external_id, uniqueness: { scope: :invoice_source_id }

  scope :recent, -> { order(issued_on: :desc, due_on: :desc, created_at: :desc) }
end
