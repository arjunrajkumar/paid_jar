require "test_helper"

class StripeConnectionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    @stripe_config = FakeStripeConfiguration.new
    InvoiceSources::Stripe::Configuration.stubs(:new).returns(@stripe_config)
    InvoiceSources::Stripe::ApiClient.any_instance.stubs(:verify_access!).returns(true)
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "install requires a PaymentReminder session" do
    get new_stripe_connection_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "install redirects to Stripe with a callback and signed state" do
    expected_account = sign_up_and_complete
    InvoiceSources::Stripe::InstallState.expects(:issue).with do |account:, nonce:, **|
      account == expected_account && nonce.present?
    end.returns("signed-install-state")

    get new_stripe_connection_url

    uri = URI(response.location)
    query = Rack::Utils.parse_query(uri.query)

    assert_equal "marketplace.stripe.test", uri.host
    assert_equal @stripe_config.redirect_uri, query.fetch("redirect_uri")
    assert_equal "signed-install-state", query.fetch("state")
  end

  test "install redirects home when Stripe App credentials are missing" do
    sign_up_and_complete
    @stripe_config.configured = false

    get new_stripe_connection_url

    assert_redirected_to root_url
    assert_equal "Stripe App credentials are not configured.", flash[:alert]
  end

  test "signed callback connects the Stripe account without OAuth tokens and queues a refresh" do
    account = sign_up_and_complete
    state = begin_install

    assert_difference -> { account.invoice_sources.stripe.count }, 1 do
      get stripe_callback_url, params: callback_params(state:)
    end

    source = account.invoice_sources.stripe.sole

    assert_redirected_to invoices_url(script_name: account.slug)
    assert_equal "Stripe connected. Your invoices are syncing now.", flash[:notice]
    assert_predicate source, :active?
    assert_equal "acct_123", source.external_account_id
    assert_equal "acct_123", source.external_account_name
    assert_nil source.access_token
    assert_nil source.refresh_token
    assert_equal %w[invoice_read event_read], source.scopes
    assert_equal "stripe_app_platform", source.provider_data.fetch("authorization_type")
    assert_equal "com.example.paymentreminder", source.provider_data.fetch("app_id")
    assert_equal "usr_123", source.provider_data.fetch("stripe_user_id")
    assert_equal false, source.provider_data.fetch("livemode")
    assert_enqueued_with(job: InvoiceSources::RefreshJob, args: [ source ])
  end

  test "callback rejects invalid state before connecting Stripe" do
    account = sign_up_and_complete
    begin_install

    get stripe_callback_url, params: callback_params(state: "wrong-state")

    assert_redirected_to root_url
    assert_equal "Stripe could not be connected securely. Please try again.", flash[:alert]
    assert_empty account.invoice_sources.stripe
    assert_no_enqueued_jobs only: InvoiceSources::RefreshJob
  end

  test "callback rejects a forged install signature" do
    account = sign_up_and_complete
    state = begin_install

    get stripe_callback_url, params: callback_params(state:).merge(install_signature: "invalid")

    assert_redirected_to root_url
    assert_equal "Stripe could not be connected securely. Please try again.", flash[:alert]
    assert_empty account.invoice_sources.stripe
    assert_no_enqueued_jobs only: InvoiceSources::RefreshJob
  end

  test "callback state can only be used once" do
    account = sign_up_and_complete
    state = begin_install
    params = callback_params(state:)

    get stripe_callback_url, params: params
    clear_enqueued_jobs

    get stripe_callback_url, params: params

    assert_redirected_to root_url
    assert_equal "Stripe could not be connected securely. Please try again.", flash[:alert]
    assert_equal 1, account.invoice_sources.stripe.count
    assert_no_enqueued_jobs only: InvoiceSources::RefreshJob
  end

  test "callback handles cancelled installation without creating a source" do
    account = sign_up_and_complete
    begin_install

    get stripe_callback_url, params: { error: "access_denied" }

    assert_redirected_to root_url
    assert_equal "Stripe installation was cancelled.", flash[:alert]
    assert_empty account.invoice_sources.stripe
  end

  test "callback rejects an environment without a platform API key" do
    account = sign_up_and_complete
    state = begin_install
    @stripe_config.configured_modes = [ true ]

    get stripe_callback_url, params: callback_params(state:, livemode: false)

    assert_redirected_to root_url
    assert_equal "Stripe could not be connected securely. Please try again.", flash[:alert]
    assert_empty account.invoice_sources.stripe
  end

  private
    def sign_up_and_complete(email_address: "owner-stripe@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: } }

      Identity.find_by!(email_address:).accounts.first.tap { clear_enqueued_jobs }
    end

    def begin_install
      get new_stripe_connection_url

      Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    end

    def callback_params(state:, livemode: false)
      attributes = {
        state:,
        user_id: "usr_123",
        account_id: "acct_123",
        livemode:
      }
      payload = JSON.generate(
        state: attributes.fetch(:state).to_s,
        user_id: attributes.fetch(:user_id),
        account_id: attributes.fetch(:account_id)
      )

      attributes.merge(install_signature: stripe_signature(payload, @stripe_config.signing_secrets.first))
    end

    def stripe_signature(payload, secret)
      timestamp = Time.current.to_i
      digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
      "t=#{timestamp},v1=#{digest}"
    end

    class FakeStripeConfiguration
      attr_accessor :configured, :configured_modes

      def initialize
        @configured = true
        @configured_modes = [ true, false ]
      end

      def configured?
        configured
      end

      def app_id
        "com.example.paymentreminder"
      end

      def install_url
        "https://marketplace.stripe.test/apps/install/paymentreminder?source=settings"
      end

      def redirect_uri
        "https://paymentreminder.test/stripe/callback"
      end

      def signing_secrets
        [ "absec_test" ]
      end

      def secret_key_configured?(livemode:)
        configured_modes.include?(livemode)
      end

      def permissions
        %w[invoice_read event_read]
      end
    end
end
