class ConversationMessages::Review
  OUTCOMES = %w[no_match_needed].freeze

  class Error < StandardError; end

  def self.complete!(
    conversation:,
    message:,
    actor_user:,
    outcome:,
    work_unit_token:,
    at: Time.current
  )
    new(
      conversation:,
      message:,
      actor_user:,
      outcome:,
      work_unit_token:,
      at:
    ).complete!
  end

  def initialize(
    conversation:,
    message:,
    actor_user:,
    outcome:,
    work_unit_token:,
    at:
  )
    @conversation = conversation.canonical
    @message = message
    @actor_user = actor_user
    @outcome = outcome.to_s
    @work_unit_token = work_unit_token
    @at = at
  end

  def complete!
    validate!
    covered = []

    EmailConnection::MailboxThreadLock.synchronize(
      account: conversation.account,
      provider_account_id: message.provider_account_id,
      provider_thread_id: message.provider_thread_id
    ) do
      conversation.with_lock do
        Conversations::WorkUnitSnapshot.verify!(
          token: work_unit_token,
          conversation:
        )
        ConversationMessage.transaction do
          covered = covered_scope.order(:id).lock.to_a
          covered.each { |candidate| review!(candidate) }
          clear_covered_attention!(covered)
        end
      end
    end

    covered
  rescue EmailConnection::MailboxThreadLock::Unavailable
    raise Error, "This Gmail thread is being updated. Please try again."
  end

  private
    attr_reader :conversation,
      :message,
      :actor_user,
      :outcome,
      :work_unit_token,
      :at

    def validate!
      raise ArgumentError, "unsupported review outcome" unless OUTCOMES.include?(outcome)
      unless actor_user.account_id == message.account_id &&
          conversation.account_id == message.account_id &&
          Conversations::ReviewWorkUnit.includes_message?(
            conversation:,
            message:
          )
        raise ActiveRecord::RecordNotFound
      end
      raise ArgumentError, "message does not require review" unless message.review_required?
    end

    def covered_scope
      Conversations::ReviewWorkUnit
        .message_scope_for(message:)
        .awaiting_review
    end

    def review!(candidate)
      original_evidence = {
        "matching_status" => candidate.matching_status,
        "matching_method" => candidate.matching_method,
        "review_reasons" => candidate.review_reasons
      }
      candidate.update!(
        reviewed_at: at,
        reviewed_by_user: actor_user,
        review_outcome: :no_match_needed
      )
      ConversationEvent.create!(
        account: candidate.account,
        conversation: candidate.conversation,
        conversation_message: candidate,
        kind: :conversation_message_reviewed,
        actor_kind: :user,
        actor_user:,
        metadata: original_evidence.merge("outcome" => outcome),
        created_at: at
      )
    end

    def clear_covered_attention!(covered)
      return if covered.empty?

      covered
        .map { |candidate| candidate.conversation.canonical }
        .uniq(&:id)
        .each do |conversation|
          Conversations::Attention.recompute!(
            conversation:,
            actor_user:,
            at:,
            metadata: {
              "outcome" => outcome,
              "covered_message_ids" => covered.map(&:id)
            }
          )
        end
    end
end
