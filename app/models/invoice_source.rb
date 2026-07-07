class InvoiceSource < ApplicationRecord
  belongs_to :account, inverse_of: :invoice_sources
  has_many :invoices, dependent: :destroy

  enum :provider, {
    xero: "xero"
  }

  enum :status, {
    pending: "pending",
    active: "active",
    disconnected: "disconnected",
    error: "error"
  }

  validates :provider, :status, presence: true
  validates :external_account_id, presence: true
  validates :provider, uniqueness: { scope: :account_id }

  scope :connected, -> { active.where.not(external_account_id: [ nil, "" ]).where.not(refresh_token: [ nil, "" ]) }

  def connect!(...)
    provider_adapter.connect!(...)
  end

  def sync_invoices!
    provider_adapter.sync_invoices!
  end

  def connected?
    active? && external_account_id.present? && refresh_token.present?
  end

  def requires_reauthorization?
    refresh_token.blank? || disconnected? || error?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def disconnect!
    update!(
      status: :disconnected,
      access_token: nil,
      refresh_token: nil,
      expires_at: nil
    )
  end

  private
    def provider_adapter
      provider_class.new(self)
    end

    def provider_class
      "InvoiceSources::#{provider.classify}".constantize
    end
end
