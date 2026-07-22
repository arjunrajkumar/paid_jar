class Identity < ApplicationRecord
  has_many :magic_links, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :external_identities, dependent: :destroy
  has_many :users, dependent: :nullify
  has_many :accounts, through: :users
  has_many :platform_admin_events,
    foreign_key: :actor_identity_id,
    dependent: :nullify,
    inverse_of: :actor_identity

  before_destroy :deactivate_users, prepend: true

  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }
  normalizes :email_address, with: ->(value) { value.strip.downcase.presence }

  def send_magic_link(**attributes)
    attributes[:purpose] = attributes.delete(:for) if attributes.key?(:for)

    magic_links.create!(attributes).tap do |magic_link|
      MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
    end
  end

  def platform_admin?
    PlatformAdminAccess.allowed?(self)
  end

  private
    def deactivate_users
      users.find_each(&:deactivate)
    end
end
