class Conversations::ReviewsController < ApplicationController
  def update
    conversation = Current.account.conversations.find(params[:conversation_id]).canonical
    message = Current.account.conversation_messages.find(params[:message_id])
    raise ActiveRecord::RecordNotFound unless
      Conversations::ReviewWorkUnit.includes_message?(
        conversation:,
        message:
      )

    ConversationMessages::Review.complete!(
      conversation:,
      message:,
      actor_user: Current.user,
      outcome: review_params.fetch(:outcome),
      work_unit_token: review_params.fetch(:work_unit_token)
    )
    redirect_to conversation_path(conversation), notice: "Review completed."
  rescue Conversations::WorkUnitSnapshot::Stale => error
    redirect_to conversation_path(conversation), alert: error.message
  rescue ConversationMessages::Review::Error => error
    redirect_to conversation_path(conversation), alert: error.message
  end

  private
    def review_params
      params.require(:review).permit(:outcome, :work_unit_token)
    end
end
