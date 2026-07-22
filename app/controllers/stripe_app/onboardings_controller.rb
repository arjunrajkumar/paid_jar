module StripeApp
  class OnboardingsController < ApplicationController
    SESSION_KEY = :stripe_installation_claim_token
    AccountSelectionError = Class.new(StandardError)

    disallow_account_scope
    allow_unauthenticated_access only: :show

    layout "public"

    def show
      return remember_claim if params[:token].present?

      @claim = active_claim
      return render_invalid_claim unless @claim

      session[:return_to_after_authenticating] = stripe_app_onboarding_url unless authenticated?
      @administered_accounts = administered_accounts
    end

    def update
      claim = active_claim || raise(InvoiceSources::Stripe::InstallationClaim::Error)
      account = selected_administered_account
      source = claim.consume!(account:)
      session.delete(SESSION_KEY)
      queue_initial_refresh(source)

      redirect_to account_settings_url(script_name: account.slug),
        notice: "Stripe connected. Your invoices are syncing now."
    rescue AccountSelectionError
      redirect_to stripe_app_onboarding_path,
        alert: "Choose a PaymentReminder account you administer."
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

      def administered_accounts
        return Account.none unless Current.identity

        accounts = Account.where(id: Current.identity.users.admin.select(:account_id))
        accounts = accounts.or(Account.where(id: exact_impersonated_account.id)) if exact_impersonated_account
        accounts.order(:name, :id)
      end

      def selected_administered_account
        account = administered_accounts.find_by(id: params[:account_id])
        return account if account

        raise AccountSelectionError
      end

      def exact_impersonated_account
        return unless platform_admin_impersonating?
        return unless Current.user&.active?
        return unless Current.account&.id == Current.user.account_id

        Current.account
      end

      def queue_initial_refresh(source)
        InvoiceSources::RefreshJob.perform_later(source)
      rescue ActiveJob::EnqueueError => error
        Rails.error.report(error, severity: :error)
      end
  end
end
