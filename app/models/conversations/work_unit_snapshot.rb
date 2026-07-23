class Conversations::WorkUnitSnapshot
  ERROR_MESSAGE = "Conversation changed; refresh and try again."

  class Stale < StandardError; end

  class << self
    def token_for(conversation:)
      conversation = conversation.canonical
      verifier.generate(
        payload_for(conversation),
        expires_in: 30.minutes,
        purpose: "conversation-work-unit"
      )
    end

    def verify!(token:, conversation:)
      conversation = conversation.canonical
      payload = verifier.verify(
        token.to_s,
        purpose: "conversation-work-unit"
      )
      raise Stale, ERROR_MESSAGE unless payload == payload_for(conversation)

      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Stale, ERROR_MESSAGE
    end

    private
      def payload_for(conversation)
        {
          "account_id" => conversation.account_id,
          "conversation_id" => conversation.id,
          "message_ids" => Conversations::ReviewWorkUnit
            .message_scope_for_conversation(conversation:)
            .order(:id)
            .pluck(:id)
        }
      end

      def verifier
        Rails.application.message_verifier("conversation-work-unit")
      end
  end
end
