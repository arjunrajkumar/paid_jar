class ConversationMessages::ManualReplyOutcome
  class << self
    def finalize!(message, at: Time.current)
      finalized = false
      conversation = message.conversation.canonical

      ConversationMessage.transaction do
        conversation.with_lock do
          message.lock!
          next unless terminal_manual_reply?(message)

          ConversationEvent.record_once!(
            conversation: message.conversation,
            conversation_message: message,
            kind: event_kind(message),
            actor_kind: :system,
            metadata: {
              "delivery_uncertain" => message.delivery_uncertain?
            },
            created_at: at
          )
          Conversations::Attention.recompute!(
            conversation:,
            at:,
            metadata: {
              "finalized_manual_reply_message_id" => message.id,
              "delivery_uncertain" => message.delivery_uncertain?
            }
          )
          finalized = true
        end
      end

      finalized
    end

    def needing_finalization
      ConversationMessage
        .kind_manual_reply
        .where(status: %i[sent failed])
        .where(
          <<~SQL.squish
            NOT EXISTS (
              SELECT 1
              FROM conversation_events
              WHERE conversation_events.conversation_message_id = conversation_messages.id
                AND conversation_events.kind = CASE
                  WHEN conversation_messages.status = 'sent'
                    THEN 'conversation_manual_reply_sent'
                  WHEN conversation_messages.delivery_uncertain = TRUE
                    THEN 'conversation_manual_reply_unconfirmed'
                  ELSE 'conversation_manual_reply_failed'
                END
            )
          SQL
        )
    end

    private
      def terminal_manual_reply?(message)
        message.kind_manual_reply? &&
          (message.status_sent? || message.status_failed?)
      end

      def event_kind(message)
        return :conversation_manual_reply_sent if message.status_sent?
        return :conversation_manual_reply_unconfirmed if message.delivery_uncertain?

        :conversation_manual_reply_failed
      end
  end
end
