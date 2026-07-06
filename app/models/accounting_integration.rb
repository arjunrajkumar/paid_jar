class AccountingIntegration < ApplicationRecord
  belongs_to :account, inverse_of: :accounting_integrations
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
  validates :external_account_id, uniqueness: { scope: [ :account_id, :provider ] }

  def provider_adapter
    provider_class.new(self)
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
    def provider_class
      "AccountingIntegrations::#{provider.classify}".constantize
    end
end
