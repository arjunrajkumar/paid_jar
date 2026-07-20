module InvoiceSources
  class StripeConnectionsController < ApplicationController
    before_action :ensure_stripe_configured

    def new
      nonce = SecureRandom.urlsafe_base64(32)
      session[:stripe_app_install_nonce] = nonce
      state = InvoiceSources::Stripe::InstallState.issue(account: Current.account, nonce:)

      redirect_to InvoiceSources::Stripe::InstallLink.new.url(state:), allow_other_host: true
    end

    def create
      nonce = session.delete(:stripe_app_install_nonce)
      return installation_denied if params[:error].present?

      account = verified_install_account(nonce:)
      livemode = parsed_livemode
      ensure_api_key_configured!(livemode:)
      verify_install_signature!

      source = account.invoice_sources.find_or_initialize_by(provider: :stripe)
      source = InvoiceSources::Stripe.new(source).connect_from_install!(
        stripe_account_id: params.require(:account_id),
        stripe_user_id: params.require(:user_id),
        livemode:
      )
      queue_initial_refresh(source)

      redirect_to invoices_url(script_name: account.slug),
        notice: "Stripe connected. Your invoices are syncing now."
    rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound,
      InvoiceSources::Stripe::InstallSignature::Error,
      InvoiceSources::Stripe::ConnectionError,
      InvoiceSources::Stripe::ApiClient::Error => error
      handle_installation_error(error)
    end

    private
      def stripe_configuration
        @stripe_configuration ||= InvoiceSources::Stripe::Configuration.new
      end

      def ensure_stripe_configured
        return if stripe_configuration.configured?

        redirect_to root_path, alert: "Stripe App credentials are not configured."
      end

      def verified_install_account(nonce:)
        account_id = InvoiceSources::Stripe::InstallState.verify(
          params.require(:state),
          nonce:,
          app_id: stripe_configuration.app_id
        )
        raise ActiveRecord::RecordNotFound if account_id.blank?

        Current.identity.users.admin.find_by!(account_id:).account
      end

      def verify_install_signature!
        InvoiceSources::Stripe::InstallSignature.new(config: stripe_configuration).verify!(
          state: params.require(:state),
          user_id: params.require(:user_id),
          account_id: params.require(:account_id),
          signature: params.require(:install_signature)
        )
      end

      def parsed_livemode
        value = params[:livemode]
        return true if value.nil? || value == true || value == "true"
        return false if value == false || value == "false"

        raise ActionController::ParameterMissing, :livemode
      end

      def ensure_api_key_configured!(livemode:)
        return if stripe_configuration.secret_key_configured?(livemode:)

        raise InvoiceSources::Stripe::ConnectionError,
          "Stripe API credentials are not configured for the selected environment."
      end

      def queue_initial_refresh(source)
        InvoiceSources::RefreshJob.perform_later(source)
      rescue ActiveJob::EnqueueError => error
        Rails.error.report(error, severity: :error)
      end

      def installation_denied
        redirect_to root_path, alert: "Stripe installation was cancelled."
      end

      def handle_installation_error(error)
        Rails.error.report(error, severity: :warning)
        redirect_to root_path,
          alert: "Stripe could not be connected securely. Please try again."
      end
  end
end
