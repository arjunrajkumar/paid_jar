require "test_helper"

class Madmin::MutationSafetyControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = sign_up_and_complete(email_address: "mutation-platform-admin@example.com")
    PlatformAdminAccess.stubs(:allowed?).returns(true)
  end

  test "read-only resources hide and reject generic mutations" do
    invoice = invoices(:xero_invoice)

    get madmin_invoice_url(invoice)
    assert_response :success
    assert_select "a", text: "Edit", count: 0
    assert_select "button", text: "Delete", count: 0

    patch madmin_invoice_url(invoice), params: { invoice: { status: "paid" } }

    assert_redirected_to madmin_invoices_url
    assert_response :see_other
    assert_not_predicate invoice.reload, :status_paid?
  end

  test "allowlisted business settings remain editable" do
    patch madmin_account_url(@account), params: { account: { name: "Renamed by Platform Admin" } }

    assert_redirected_to madmin_account_url(@account)
    assert_equal "Renamed by Platform Admin", @account.reload.name
  end

  test "account creation and deletion are rejected" do
    assert_no_difference -> { Account.count } do
      post madmin_accounts_url, params: { account: { name: "Unsafe Account" } }
      delete madmin_account_url(@account)
    end

    assert Account.exists?(@account.id)
  end

  private
    def sign_up_and_complete(email_address:)
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Platform Admin" } }

      Identity.find_by!(email_address:).accounts.first
    end
end
