module StripeApp
  class OnboardingClaimsController < ActionController::API
    before_action :set_cors_headers

    def create
      configuration = InvoiceSources::Stripe::Configuration.new
      context = InvoiceSources::Stripe::AppRequest.new(config: configuration).verify!(
        payload: request.raw_post,
        signature: request.headers["Stripe-Signature"]
      )
      unless configuration.secret_key_configured?(livemode: context.livemode)
        raise InvoiceSources::Stripe::AppRequest::Error,
          "Stripe API credentials are not configured for this environment."
      end
      _, token = InvoiceSources::Stripe::InstallationClaim.issue!(
        stripe_account_id: context.stripe_account_id,
        stripe_user_id: context.stripe_user_id,
        livemode: context.livemode,
        request_digest: context.request_digest
      )

      render json: { onboarding_url: onboarding_url(token) }, status: :created
    rescue InvoiceSources::Stripe::AppRequest::Error,
      InvoiceSources::Stripe::InstallationClaim::Error => error
      Rails.error.report(error, severity: :warning)
      render json: { error: "Stripe App request could not be verified." }, status: :bad_request
    end

    def preflight
      head :no_content
    end

    private
      def set_cors_headers
        response.set_header("Access-Control-Allow-Origin", "*")
        response.set_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        response.set_header("Access-Control-Allow-Headers", "Content-Type, Stripe-Signature")
        response.set_header("Access-Control-Max-Age", "600")
        response.set_header("Cache-Control", "no-store")
      end

      def onboarding_url(token)
        host = InvoiceSources::Stripe::Configuration.new.host.chomp("/")
        "#{host}#{stripe_app_onboarding_path(token: token)}"
      end
  end
end
