class InvoiceEvent < ApplicationRecord
  belongs_to :invoice

  validates :situation, :asked_at, presence: true
end
