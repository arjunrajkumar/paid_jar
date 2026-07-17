class Account < ApplicationRecord
  has_many :invoice_sources, dependent: :destroy
  has_many :customers, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :invoice_reminders, dependent: :destroy, inverse_of: :account
  has_many :users, dependent: :destroy
  has_many :customer_segments, dependent: :destroy, inverse_of: :account

  include CustomerSegments, InvoiceSchedules, Remindable

  before_create :assign_external_account_id

  validates :name, presence: true
  validates :invoice_reminder_from_email,
    format: { with: URI::MailTo::EMAIL_REGEXP },
    allow_blank: true
  validates :invoice_reminder_from_email, length: { maximum: 254 }
  validates :invoice_reminder_from_email,
    presence: true,
    if: :automatic_invoice_reminders_enabled?
  normalizes :invoice_reminder_from_email,
    with: ->(value) { value.strip.downcase.presence }

  class << self
    def create_with_owner(account:, owner:)
      account_attributes = account.with_defaults(
        invoice_reminder_from_email: owner[:identity]&.email_address
      )

      transaction do
        create!(**account_attributes).tap do |account|
          account.users.create!(role: :system, name: "System")
          account.users.create!(**owner.with_defaults(role: :owner, verified_at: Time.current))
        end
      end
    end
  end

  def slug
    "/#{AccountSlug.encode(external_account_id)}"
  end

  def active?
    true
  end

  private
    def assign_external_account_id
      self.external_account_id ||= ExternalIdSequence.next
    end
end
