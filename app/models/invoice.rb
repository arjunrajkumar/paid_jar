class Invoice < ApplicationRecord
  belongs_to :account, inverse_of: :invoices
  belongs_to :accounting_integration, inverse_of: :invoices
  has_many :invoice_events, dependent: :destroy
  has_one :invoice_state, dependent: :destroy

  validates :external_id, presence: true
  validates :external_id, uniqueness: { scope: :accounting_integration_id }

  scope :recent, -> { order(issued_on: :desc, due_on: :desc, created_at: :desc) }
end
