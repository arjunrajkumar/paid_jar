module StripeApp
  class OnboardingsController < ApplicationController
    SESSION_KEY = :stripe_installation_claim_token

    disallow_account_scope
    allow_unauthenticated_access only: :show

    layout "public"

    def show
      return remember_claim if params[:token].present?

      @claim = active_claim
      return render_invalid_claim unless @claim

      session[:return_to_after_authenticating] = stripe_app_onboarding_url unless authenticated?
      @administered_account = administered_account
    end

    def update
      claim = active_claim || raise(InvoiceSources::Stripe::InstallationClaim::Error)
      account = administered_account
      raise InvoiceSources::Stripe::InstallationClaim::Error unless account
      source = claim.consume!(account:)
      session.delete(SESSION_KEY)
      queue_initial_refresh(source)

      redirect_to account_settings_url(script_name: account.slug),
        notice: "Stripe connected. Your invoices are syncing now."
    rescue InvoiceSources::Stripe::InstallationClaim::Error,
      InvoiceSources::Stripe::ConnectionError,
      InvoiceSources::Stripe::ApiClient::Error => error
      Rails.error.report(error, severity: :warning)
      session.delete(SESSION_KEY)
      redirect_to stripe_app_onboarding_path,
        alert: "This Stripe connection link is no longer valid. Start again from Stripe."
    end

    private
      def remember_claim
        claim = InvoiceSources::Stripe::InstallationClaim.active_for_token(params[:token])
        return render_invalid_claim unless claim

        session[SESSION_KEY] = params[:token]
        redirect_to stripe_app_onboarding_path
      end

      def active_claim
        InvoiceSources::Stripe::InstallationClaim.active_for_token(session[SESSION_KEY])
      end

      def render_invalid_claim
        session.delete(SESSION_KEY)
        render :invalid, status: :unprocessable_entity
      end

      def administered_account
        return unless Current.identity

        Current.identity.users.admin.includes(:account).first&.account
      end

      def queue_initial_refresh(source)
        InvoiceSources::RefreshJob.perform_later(source)
      rescue ActiveJob::EnqueueError => error
        Rails.error.report(error, severity: :error)
      end
  end
end
