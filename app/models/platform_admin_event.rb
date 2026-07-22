class PlatformAdminEvent < ApplicationRecord
  belongs_to :actor_identity,
    class_name: "Identity",
    inverse_of: :platform_admin_events,
    optional: true
  belongs_to :account,
    inverse_of: :platform_admin_events,
    optional: true
  belongs_to :target, polymorphic: true, optional: true

  attribute :metadata, default: -> { {} }

  validates :actor_email_address, :action, presence: true

  class << self
    def record!(actor:, action:, target: nil, account: account_for(target), metadata: {})
      create!(
        actor_identity: actor,
        actor_email_address: actor.email_address,
        action:,
        target:,
        account:,
        metadata:
      )
    end

    private
      def account_for(target)
        return target if target.is_a?(Account)
        return target.account if target&.respond_to?(:account)
        return target.customer.account if target&.respond_to?(:customer)
        return target.user.account if target&.respond_to?(:user)

        nil
      end
  end
end
