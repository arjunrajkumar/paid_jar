class User < ApplicationRecord
  include User::Role

  belongs_to :account
  belongs_to :identity, optional: true

  validates :name, presence: true

  def deactivate
    transaction do
      update! active: false, identity: nil
    end
  end

  def verified?
    verified_at.present?
  end

  def verify
    update!(verified_at: Time.current) unless verified?
  end
end
