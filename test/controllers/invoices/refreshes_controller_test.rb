require "test_helper"

class Invoices::RefreshesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "create requires a PaymentReminder session" do
    post invoice_refresh_url(invoices(:xero_invoice))

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "create enqueues invoice refresh" do
    account = sign_up_and_complete
    source = create_xero_source(account)
    invoice = create_invoice(source, account)

    assert_enqueued_with(job: Invoices::RefreshJob, args: [ invoice ]) do
      post invoice_refresh_url(invoice)
    end

    assert_redirected_to home_url
    assert_equal "Invoice INV-REF refresh started.", flash[:notice]
  end

  test "create skips invoices from disconnected invoice sources" do
    account = sign_up_and_complete(email_address: "owner-invoice-refresh-disconnected@example.com")
    source = account.invoice_sources.create!(
      provider: :stripe,
      status: :disconnected,
      external_account_id: "acct_disconnected",
      external_account_name: "Disconnected Stripe"
    )
    invoice = create_invoice(source, account)

    assert_no_enqueued_jobs do
      post invoice_refresh_url(invoice)
    end

    assert_redirected_to invoice_sources_url
    assert_equal "Reconnect the invoice source first.", flash[:alert]
  end

  private
    def create_invoice(source, account)
      source.invoices.create!(
        account: account,
        external_id: "invoice-refresh",
        number: "INV-REF",
        contact_name: "Refresh Customer",
        status: "AUTHORISED",
        currency: "USD",
        total: 300,
        amount_due: 125,
        issued_on: Date.new(2026, 7, 1),
        due_on: Date.new(2026, 7, 31)
      )
    end

    def create_xero_source(account)
      account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "tenant-refresh",
        external_account_name: "PaymentReminder Xero",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
    end

    def sign_up_and_complete(email_address: "owner-invoice-refresh@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end
