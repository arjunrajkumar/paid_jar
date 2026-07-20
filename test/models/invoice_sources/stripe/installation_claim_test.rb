require "test_helper"

module InvoiceSources
  class Stripe
    class InstallationClaimTest < ActiveSupport::TestCase
      test "issues an expiring claim without storing the plaintext token" do
        freeze_time do
          claim, token = InstallationClaim.issue!(
            stripe_account_id: "acct_claim",
            stripe_user_id: "usr_claim",
            livemode: false,
            request_digest: request_digest
          )

          assert token.present?
          refute_equal token, claim.token_digest
          assert_equal 64, claim.token_digest.length
          assert_equal 64, claim.request_digest.length
          assert_equal 15.minutes.from_now, claim.expires_at
          assert_equal claim, InstallationClaim.active_for_token(token)
          assert_nil InstallationClaim.active_for_token("wrong-token")
        end
      end

      test "consumes a claim once and connects the account" do
        claim, token = InstallationClaim.issue!(
          stripe_account_id: "acct_installation_claim",
          stripe_user_id: "usr_installation_claim",
          livemode: false,
          request_digest: request_digest
        )

        with_stripe_credentials do
          source = claim.consume!(account: accounts(:paid_jar))

          assert_predicate source, :active?
          assert_equal "acct_installation_claim", source.external_account_id
          assert_equal false, source.provider_data.fetch("livemode")
          assert_equal "usr_installation_claim", source.provider_data.fetch("stripe_user_id")
          assert_equal accounts(:paid_jar), claim.reload.account
          assert claim.consumed_at.present?
          assert_nil InstallationClaim.active_for_token(token)

          assert_raises(InstallationClaim::Error) do
            claim.consume!(account: accounts(:paid_jar))
          end
        end
      end

      test "does not consume an expired claim" do
        claim, token = InstallationClaim.issue!(
          stripe_account_id: "acct_expired_claim",
          stripe_user_id: "usr_expired_claim",
          livemode: false,
          request_digest: request_digest
        )
        claim.update!(expires_at: 1.minute.ago)

        assert_nil InstallationClaim.active_for_token(token)
        with_stripe_credentials do
          assert_raises(InstallationClaim::Error) do
            claim.consume!(account: accounts(:paid_jar))
          end
        end

        assert_nil claim.reload.consumed_at
      end

      test "keeps a claim available when the selected API environment is not configured" do
        claim, = InstallationClaim.issue!(
          stripe_account_id: "acct_missing_key",
          stripe_user_id: "usr_missing_key",
          livemode: true,
          request_digest: request_digest
        )

        with_stripe_credentials(secret_keys: { test: "sk_test_123" }) do
          error = assert_raises(InstallationClaim::Error) do
            claim.consume!(account: accounts(:paid_jar))
          end

          assert_match(/credentials are not configured/, error.message)
        end

        assert_nil claim.reload.consumed_at
        assert_nil claim.account
      end

      test "rejects a request digest that has already issued a claim" do
        duplicate_request_digest = request_digest
        InstallationClaim.issue!(
          stripe_account_id: "acct_first_claim",
          stripe_user_id: "usr_first_claim",
          livemode: false,
          request_digest: duplicate_request_digest
        )

        assert_no_difference -> { InstallationClaim.count } do
          error = assert_raises(InstallationClaim::Error) do
            InstallationClaim.issue!(
              stripe_account_id: "acct_second_claim",
              stripe_user_id: "usr_second_claim",
              livemode: false,
              request_digest: duplicate_request_digest
            )
          end

          assert_equal "This Stripe App request was already used.", error.message
        end
      end

      private
        def request_digest
          SecureRandom.hex(32)
        end

        def with_stripe_credentials(secret_keys: { live: "sk_live_123", test: "sk_test_123" })
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = {
            app_id: "com.example.paymentreminder",
            secret_keys:
          }
          Rails.application.stubs(:credentials).returns(credentials)
          InvoiceSources::Stripe::ApiClient.any_instance.stubs(:verify_access!).returns(true)
          yield
        end
    end
  end
end
