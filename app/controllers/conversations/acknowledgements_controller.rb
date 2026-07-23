class Conversations::AcknowledgementsController < ApplicationController
  def create
    conversation = Current.account.conversations.find(params[:conversation_id]).canonical
    Conversations::Acknowledgement.call(
      conversation:,
      actor_user: Current.user,
      work_unit_token: acknowledgement_params.fetch(:work_unit_token)
    )

    redirect_to conversation_path(conversation), notice: "Conversation marked handled."
  rescue Conversations::WorkUnitSnapshot::Stale => error
    redirect_to conversation_path(conversation), alert: error.message
  end

  private
    def acknowledgement_params
      params.require(:acknowledgement).permit(:work_unit_token)
    end
end
