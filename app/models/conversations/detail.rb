class Conversations::Detail
  attr_reader :conversation, :timeline

  def self.call(conversation:)
    new(conversation:)
  end

  def initialize(conversation:)
    @conversation = conversation.canonical
    @timeline = Conversations::Timeline.new(conversation: @conversation)
  end

  def reply_targets
    return [] unless conversation.invoice

    provider_account_id = conversation.account.email_connection&.provider_account_id
    return [] if provider_account_id.blank?

    timeline.messages
      .select do |message|
        message.direction_inbound? &&
          message.provider_account_id == provider_account_id &&
          message.provider_thread_id.present?
      end
      .group_by { |message| [ message.provider_account_id, message.provider_thread_id ] }
      .filter_map do |_thread, messages|
        messages.reverse_each.filter_map do |message|
          ConversationMessages::ManualReply.reply_target_for(
            conversation:,
            reply_to_message: message
          )
        end.first
      end
      .sort_by { |target| [ target.message.occurred_at, target.message.id ] }
  end
end
