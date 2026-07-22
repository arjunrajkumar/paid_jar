class Conversation < ApplicationRecord
  STATUSES = {
    open: "open",
    resolved: "resolved"
  }.freeze

  belongs_to :account, inverse_of: :conversations
  belongs_to :customer, optional: true, inverse_of: :conversations
  belongs_to :invoice, optional: true, inverse_of: :conversation
  has_many :conversation_messages,
    dependent: :restrict_with_exception,
    inverse_of: :conversation
  has_many :conversation_events,
    dependent: :delete_all,
    inverse_of: :conversation

  enum :status, STATUSES, prefix: true, validate: true

  validates :invoice_id, uniqueness: true, allow_nil: true
  validate :customer_matches_account
  validate :invoice_matches_account
  validate :customer_matches_invoice
  validate :resolved_at_matches_status

  after_create :record_creation_event

  class << self
    def for_invoice!(invoice:)
      unless invoice&.persisted?
        raise ArgumentError, "invoice must be persisted"
      end

      find_by(invoice:) || create_or_find_by!(invoice:) do |conversation|
        conversation.account = invoice.account
        conversation.customer = invoice.customer
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
      find_by(invoice:) || raise(error)
    end
  end

  def resolve!(actor_user: nil, at: Time.current)
    transition_to!(
      status: :resolved,
      resolved_at: at,
      event_kind: :conversation_resolved,
      actor_user:,
      at:
    )
  end

  def reopen!(actor_user: nil, at: Time.current)
    transition_to!(
      status: :open,
      resolved_at: nil,
      event_kind: :conversation_reopened,
      actor_user:,
      at:
    )
  end

  private
    def transition_to!(status:, resolved_at:, event_kind:, actor_user:, at:)
      with_lock do
        next if self.status == status.to_s

        update!(status:, resolved_at:)
        conversation_events.create!(
          account:,
          kind: event_kind,
          actor_kind: actor_user ? :user : :system,
          actor_user:,
          metadata: {},
          created_at: at
        )
      end

      self
    end

    def record_creation_event
      ConversationEvent.record!(
        conversation: self,
        kind: :conversation_created,
        actor_kind: :system
      )
    end

    def customer_matches_account
      return if account.blank? || customer.blank? || customer.account == account

      errors.add(:customer, "must belong to the conversation account")
    end

    def invoice_matches_account
      return if account.blank? || invoice.blank? || invoice.account == account

      errors.add(:invoice, "must belong to the conversation account")
    end

    def customer_matches_invoice
      return if invoice.blank? || customer == invoice.customer

      errors.add(:customer, "must match the conversation invoice customer")
    end

    def resolved_at_matches_status
      if status_open? && resolved_at.present?
        errors.add(:resolved_at, "must be blank for an open conversation")
      elsif status_resolved? && resolved_at.blank?
        errors.add(:resolved_at, "must be present for a resolved conversation")
      end
    end
end
