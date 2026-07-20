require "test_helper"

module StripeApp
  class OnboardingsControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      clear_enqueued_jobs
      InvoiceSources::Stripe::Configuration.stubs(:new).returns(FakeStripeConfiguration.new)
      InvoiceSources::Stripe::ApiClient.any_instance.stubs(:verify_access!).returns(true)
    end

    teardown do
      clear_enqueued_jobs
      clear_performed_jobs
    end

    test "claim token is remembered in the session and removed from the browser URL" do
      _, token = issue_claim

      get stripe_app_onboarding_url(token:)

      assert_redirected_to stripe_app_onboarding_url

      follow_redirect!

      assert_response :success
      assert_select "h1", "Connect Stripe"
      assert_select "a[href=?]", new_session_path, "Sign in to PaymentReminder"
      assert_select "a[href=?]", new_signup_path, "Create a PaymentReminder account"
      assert_not_includes request.url, token
    end

    test "invalid or expired claim renders the safe restart page" do
      claim, token = issue_claim
      claim.update!(expires_at: 1.minute.ago)

      get stripe_app_onboarding_url(token:)

      assert_response :unprocessable_entity
      assert_select "h1", "Start again from Stripe"
      assert_not_includes response.body, token
    end

    test "owner can attach a claim to their account and queue the initial refresh" do
      account = sign_up_and_complete
      claim, token = issue_claim
      remember_claim(token)

      get stripe_app_onboarding_url

      assert_response :success
      assert_select "form[action=?]", stripe_app_onboarding_path
      assert_select "input[name=account_id]", count: 0

      assert_difference -> { account.invoice_sources.stripe.count }, 1 do
        patch stripe_app_onboarding_url
      end

      source = account.invoice_sources.stripe.sole

      assert_redirected_to account_settings_url(script_name: account.slug)
      assert_equal "Stripe connected. Your invoices are syncing now.", flash[:notice]
      assert_equal account, claim.reload.account
      assert claim.consumed_at.present?
      assert_not_predicate claim, :active?
      assert_equal "acct_123", source.external_account_id
      assert_equal "usr_123", source.provider_data.fetch("stripe_user_id")
      assert_equal false, source.provider_data.fetch("livemode")
      assert_enqueued_with(job: InvoiceSources::RefreshJob, args: [ source ])
    end

    test "claim cannot be consumed twice" do
      account = sign_up_and_complete
      claim, token = issue_claim
      remember_claim(token)

      patch stripe_app_onboarding_url
      clear_enqueued_jobs

      patch stripe_app_onboarding_url

      assert_redirected_to stripe_app_onboarding_url
      assert_equal "This Stripe connection link is no longer valid. Start again from Stripe.", flash[:alert]
      assert claim.reload.consumed_at.present?
      assert_equal 1, account.invoice_sources.stripe.count
      assert_no_enqueued_jobs only: InvoiceSources::RefreshJob
    end

    test "authenticated onboarding does not change a later sign-in destination" do
      account = sign_up_and_complete(email_address: "owner-stripe-return@example.com")
      _, token = issue_claim
      remember_claim(token)

      get stripe_app_onboarding_url
      patch stripe_app_onboarding_url
      assert_redirected_to account_settings_url(script_name: account.slug)

      delete session_url
      post session_url, params: { email_address: "owner-stripe-return@example.com" }
      post session_magic_link_url, params: { code: MagicLink.last.code }

      assert_redirected_to root_url
    end

    test "non-admin cannot attach a claim to an account" do
      account = sign_up_and_complete(email_address: "member-stripe@example.com")
      Identity.find_by!(email_address: "member-stripe@example.com").users.sole.update!(role: :member)
      claim, token = issue_claim
      remember_claim(token)

      get stripe_app_onboarding_url

      assert_response :success
      assert_select "p", text: /owner or administrator/
      assert_select "form", count: 0

      patch stripe_app_onboarding_url

      assert_redirected_to stripe_app_onboarding_url
      assert_predicate claim.reload, :active?
      assert_empty account.invoice_sources.stripe
      assert_no_enqueued_jobs only: InvoiceSources::RefreshJob
    end

    test "new signup returns to the remembered Stripe onboarding claim" do
      _, token = issue_claim
      remember_claim(token)
      get stripe_app_onboarding_url

      post signup_url, params: { signup: { email_address: "new-stripe-owner@example.com" } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Stripe Owner" } }

      assert_redirected_to stripe_app_onboarding_url

      follow_redirect!

      assert_response :success
      assert_select "form[action=?]", stripe_app_onboarding_path
      assert_select "input[name=account_id]", count: 0
    end

    private
      def sign_up_and_complete(email_address: "owner-onboarding@example.com")
        post signup_url, params: { signup: { email_address: } }
        post session_magic_link_url, params: { code: MagicLink.last.code }
        post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

        Identity.find_by!(email_address:).accounts.first.tap { clear_enqueued_jobs }
      end

      def issue_claim
        InvoiceSources::Stripe::InstallationClaim.issue!(
          stripe_account_id: "acct_123",
          stripe_user_id: "usr_123",
          livemode: false,
          request_digest: SecureRandom.hex(32)
        )
      end

      def remember_claim(token)
        get stripe_app_onboarding_url(token:)
        assert_redirected_to stripe_app_onboarding_url
      end

      class FakeStripeConfiguration
        def secret_key_configured?(livemode:)
          [ true, false ].include?(livemode)
        end

        def permissions
          %w[invoice_read event_read]
        end

        def app_id
          "com.example.paymentreminder"
        end
      end
  end
end
