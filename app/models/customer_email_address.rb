class CustomerEmailAddress < ApplicationRecord
  belongs_to :customer, inverse_of: :additional_email_addresses

  normalizes :email, with: ->(email) { email.to_s.strip.downcase.presence }

  validates :email, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :email, length: { maximum: 254 }
  validates :email, uniqueness: { scope: :customer_id, case_sensitive: false }
  validate :email_differs_from_synced_email

  private
    def email_differs_from_synced_email
      return if email.blank? || customer&.email.blank?
      return unless email == customer.email.to_s.strip.downcase

      errors.add(:email, "is already the synced email")
    end
end
