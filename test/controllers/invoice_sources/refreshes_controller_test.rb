require "test_helper"

class InvoiceSources::RefreshesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "create requires a PaidJar session" do
    post invoice_source_refresh_url(invoice_sources(:xero))

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "create enqueues invoice source refresh" do
    account = sign_up_and_complete
    source = create_xero_source(account)

    assert_enqueued_with(job: InvoiceSources::RefreshJob, args: [ source ]) do
      post invoice_source_refresh_url(source)
    end

    assert_redirected_to invoices_url
    assert_equal "PaidJar Xero invoice refresh started.", flash[:notice]
  end

  test "create skips disconnected invoice source" do
    account = sign_up_and_complete(email_address: "owner-source-refresh-disconnected@example.com")
    source = account.invoice_sources.create!(
      provider: :xero,
      status: :disconnected,
      external_account_id: "tenant-disconnected",
      external_account_name: "Disconnected Xero"
    )

    assert_no_enqueued_jobs do
      post invoice_source_refresh_url(source)
    end

    assert_redirected_to invoice_sources_url
    assert_equal "Connect an invoice source first.", flash[:alert]
  end

  private
    def create_xero_source(account)
      account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "tenant-refresh",
        external_account_name: "PaidJar Xero",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
    end

    def sign_up_and_complete(email_address: "owner-source-refresh@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end
