class Conversations::RepliesController < ApplicationController
  def create
    conversation = Current.account.conversations.find(params[:conversation_id]).canonical
    anchor = Current.account.conversation_messages.find(reply_params.fetch(:anchor_message_id))
    message = ConversationMessages::ManualReply.enqueue!(
      conversation:,
      reply_to_message: anchor,
      actor_user: Current.user,
      body: reply_params.fetch(:body),
      idempotency_key: reply_params.fetch(:idempotency_key),
      composer_token: reply_params.fetch(:composer_token)
    )

    if message.status_failed?
      redirect_to conversation_path(conversation), alert: "The reply could not be queued."
    else
      redirect_to conversation_path(conversation), notice: "Reply queued."
    end
  rescue ConversationMessages::ManualReply::Error, ArgumentError => error
    redirect_to conversation_path(conversation), alert: error.message
  end

  private
    def reply_params
      params.require(:reply).permit(
        :body,
        :anchor_message_id,
        :idempotency_key,
        :composer_token
      )
    end
end
