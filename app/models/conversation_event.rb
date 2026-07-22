class ConversationEvent < ApplicationRecord
  ACTOR_KINDS = {
    system: "system",
    user: "user",
    ai: "ai"
  }.freeze
  KINDS = {
    conversation_created: "conversation_created",
    conversation_resolved: "conversation_resolved",
    conversation_reopened: "conversation_reopened"
  }.freeze

  belongs_to :account, inverse_of: :conversation_events
  belongs_to :conversation, inverse_of: :conversation_events
  belongs_to :conversation_message, optional: true, inverse_of: :conversation_events
  belongs_to :actor_user,
    class_name: "User",
    optional: true,
    inverse_of: :conversation_events

  enum :actor_kind, ACTOR_KINDS, prefix: true, validate: true
  enum :kind, KINDS, prefix: true, validate: true

  attribute :metadata, default: -> { {} }

  before_validation :derive_account_from_conversation

  validates :metadata, exclusion: { in: [ nil ], message: "can't be blank" }
  validate :account_matches_conversation
  validate :conversation_message_matches_event
  validate :actor_user_matches_event

  scope :chronological, -> { order(:created_at, :id) }

  class << self
    def record!(
      conversation:,
      kind:,
      actor_kind:,
      actor_user: nil,
      conversation_message: nil,
      metadata: {}
    )
      create!(
        conversation:,
        kind:,
        actor_kind:,
        actor_user:,
        conversation_message:,
        metadata:
      )
    end
  end

  def readonly?
    persisted? || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, "Conversation events are append-only"
  end

  private
    def derive_account_from_conversation
      self.account = conversation.account if conversation.present?
    end

    def account_matches_conversation
      return if account.blank? || conversation.blank? || account == conversation.account

      errors.add(:account, "must match conversation account")
    end

    def conversation_message_matches_event
      return if conversation_message.blank? || account.blank? || conversation.blank?
      return if conversation_message.account == account && conversation_message.conversation == conversation

      errors.add(:conversation_message, "must belong to the same account and conversation")
    end

    def actor_user_matches_event
      if actor_user.present? && account.present? && actor_user.account != account
        errors.add(:actor_user, "must belong to the conversation account")
      end

      if actor_kind_user?
        errors.add(:actor_user, "must be present for a user event") if actor_user.blank?
      elsif actor_user.present?
        errors.add(:actor_user, "must be blank for a system or AI event")
      end
    end
end
