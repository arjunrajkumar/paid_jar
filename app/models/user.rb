class User < ApplicationRecord
  include User::Role

  belongs_to :account
  belongs_to :identity, optional: true
  has_many :notification_subscriptions, dependent: :destroy, inverse_of: :user
  has_many :conversation_events,
    foreign_key: :actor_user_id,
    dependent: :nullify,
    inverse_of: :actor_user

  validates :name, presence: true

  def deactivate
    transaction do
      update! active: false, identity: nil
    end
  end
end
