class Conversations::Attention
  class << self
    def require_for_message!(message)
      requires_attention = message.awaiting_review? ||
        (message.direction_inbound? && message.status_received?)
      return unless requires_attention

      message.conversation.require_attention!(at: message.occurred_at)
    end

    def require_for_inbound!(message)
      require_for_message!(message)
    end

    def clear_for_outbound!(message)
      return unless message.direction_outbound? && message.status_sent?

      recompute!(
        conversation: message.conversation,
        at: message.occurred_at,
        metadata: {
          "cleared_by_message_id" => message.id,
          "provider_thread_id" => message.provider_thread_id
        }
      )
    end

    def recompute!(
      conversation:,
      actor_user: nil,
      at: Time.current,
      metadata: {}
    )
      target = conversation.canonical
      target.with_lock do
        previous_attention_at = target.attention_required_at
        outstanding_at = outstanding_attention_at(target)
        next if previous_attention_at == outstanding_at

        target.update!(attention_required_at: outstanding_at)
        if previous_attention_at.present? && outstanding_at.nil?
          target.conversation_events.create!(
            account: target.account,
            kind: :conversation_attention_cleared,
            actor_kind: actor_user ? :user : :system,
            actor_user:,
            metadata:,
            created_at: at
          )
        end
      end
      target
    end

    private
      def outstanding_attention_at(conversation)
        messages = Conversations::ReviewWorkUnit
          .message_scope_for_conversation(conversation:)
        [
          latest_review_attention(messages),
          latest_unanswered_inbound(messages, conversation),
          latest_manual_reply_failure(messages, conversation),
          unknown_attention_at(messages, conversation)
        ].compact.max
      end

      def unknown_attention_at(messages, conversation)
        current = conversation.attention_required_at
        latest_message_at = messages.maximum(
          Arel.sql("COALESCE(received_at, sent_at, created_at)")
        )
        current if current.present? &&
          (latest_message_at.nil? || current > latest_message_at)
      end

      def latest_review_attention(messages)
        messages.awaiting_review.maximum(
          Arel.sql("COALESCE(received_at, sent_at, created_at)")
        )
      end

      def latest_unanswered_inbound(messages, conversation)
        acknowledgement = latest_user_acknowledgement(conversation)
        inbound = messages.where(
          direction: ConversationMessage::DIRECTIONS.fetch(:inbound),
          kind: ConversationMessage::KINDS.fetch(:customer_email),
          status: ConversationMessage::STATUSES.fetch(:received)
        )
        inbound = inbound.where(review_required: false).or(
          inbound.where(
            review_outcome: ConversationMessage::REVIEW_OUTCOMES.fetch(:manual_match)
          )
        )
        if acknowledgement
          acknowledged_message_ids = Array(
            acknowledgement.metadata["visible_message_ids"]
          ).map(&:to_i)
          inbound = inbound.where.not(id: acknowledged_message_ids) if
            acknowledged_message_ids.any?
        end
        sent_by_thread = messages
          .where(
            direction: ConversationMessage::DIRECTIONS.fetch(:outbound),
            status: ConversationMessage::STATUSES.fetch(:sent)
          )
          .where.not(provider_account_id: nil, provider_thread_id: nil)
          .group(:provider_account_id, :provider_thread_id)
          .maximum(:sent_at)

        inbound.filter_map do |message|
          sent_at = sent_by_thread[
            [ message.provider_account_id, message.provider_thread_id ]
          ]
          message.received_at if sent_at.nil? || sent_at < message.received_at
        end.max
      end

      def latest_manual_reply_failure(messages, conversation)
        acknowledgement = latest_user_acknowledgement(conversation)
        events = conversation.account.conversation_events
          .where(
            conversation_id: Conversations::ReviewWorkUnit
              .conversation_ids_for(conversation:)
          )
          .where(
            kind: %i[
              conversation_manual_reply_failed
              conversation_manual_reply_unconfirmed
            ]
          )
          .includes(conversation_message: :reply_to_message)
        events = events.where("conversation_events.id > ?", acknowledgement.id) if
          acknowledgement

        events.filter_map do |event|
          next if event.conversation_message&.status_sent?

          event.conversation_message&.reply_to_message&.occurred_at ||
            event.created_at
        end.max
      end

      def latest_user_acknowledgement(conversation)
        conversation.conversation_events
          .kind_conversation_attention_cleared
          .actor_kind_user
          .order(id: :desc)
          .detect { |event| event.metadata["outcome"] == "handled" }
      end
  end
end
