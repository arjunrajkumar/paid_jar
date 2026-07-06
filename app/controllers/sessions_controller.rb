class SessionsController < ApplicationController
  disallow_account_scope
  require_unauthenticated_access except: :destroy
  rate_limit to: 10, within: 3.minutes, only: :create, with: :rate_limit_exceeded

  layout "public"

  def new
  end

  def create
    if identity = Identity.find_by(email_address: email_address)
      sign_in identity
    else
      respond_to do |format|
        format.html { redirect_to new_session_path, alert: "We couldn't find that email address. Try signing up instead." }
        format.json { render json: { message: "We couldn't find that email address. Try signing up instead." }, status: :not_found }
      end
    end
  end

  def destroy
    terminate_session

    respond_to do |format|
      format.html { redirect_to new_session_path, notice: "Signed out." }
      format.json { head :no_content }
    end
  end

  private
    def email_address
      params.expect(:email_address).to_s.strip.downcase
    end

    def sign_in(identity)
      redirect_to_session_magic_link identity.send_magic_link
    end

    def rate_limit_exceeded
      respond_to do |format|
        format.html { redirect_to new_session_path, alert: "Try again later." }
        format.json { render json: { message: "Try again later." }, status: :too_many_requests }
      end
    end
end
