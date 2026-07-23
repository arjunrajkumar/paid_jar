class Conversations::MatchesController < ApplicationController
  before_action :set_conversation
  before_action :set_message
  before_action :set_candidates

  def new
  end

  def create
    target = Conversations::ManualMatcher.call(
      source_conversation: @conversation,
      reviewed_message: @message,
      target_invoice: selected_invoice,
      target_customer: selected_customer,
      actor_user: Current.user,
      work_unit_token: match_params.fetch(:work_unit_token)
    )
    redirect_to conversation_path(target), notice: "Conversation matched."
  rescue Conversations::ManualMatcher::Error,
      Conversations::WorkUnitSnapshot::Stale,
      ActiveRecord::RecordInvalid => error
    flash.now[:alert] = error.message
    render :new, status: :unprocessable_entity
  end

  private
    def set_conversation
      @conversation = Current.account.conversations.find(params[:conversation_id])
      redirect_to conversation_path(@conversation.canonical) if
        @conversation.canonical_conversation_id.present?
    end

    def set_message
      message_id = params[:message_id] || match_params[:message_id]
      @message = Current.account.conversation_messages.find(message_id)
      raise ActiveRecord::RecordNotFound unless
        Conversations::ReviewWorkUnit.includes_message?(
          conversation: @conversation,
          message: @message
        )
    end

    def set_candidates
      @invoices = Current.account.invoices
        .includes(:customer)
        .order(due_on: :desc, id: :desc)
      @customers = Current.account.customers.order(:name, :id)
    end

    def selected_invoice
      return if match_params[:invoice_id].blank?

      @selected_invoice ||= Current.account.invoices.find(match_params[:invoice_id])
    end

    def selected_customer
      return @selected_invoice.customer if selected_invoice
      return if match_params[:customer_id].blank?

      Current.account.customers.find(match_params[:customer_id])
    end

    def match_params
      @match_params ||= params.fetch(:match, {}).permit(
        :message_id,
        :invoice_id,
        :customer_id,
        :work_unit_token
      )
    end
end
