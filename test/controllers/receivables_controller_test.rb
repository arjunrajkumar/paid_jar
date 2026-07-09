require "test_helper"

class ReceivablesControllerTest < ActionDispatch::IntegrationTest
  test "index requires a PaymentReminder session" do
    get receivables_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "index shows the receivables dashboard" do
    sign_up_and_complete

    get receivables_url

    assert_response :success
    assert_select "h1", "Accounts Receivable Dashboard"
    assert_select "#nav.app-nav[data-controller='toggle-class']"
    assert_select "#nav button[data-action='toggle-class#toggle'][aria-label='Toggle navigation']"
    assert_select "#nav a[aria-current='page']", "Home"
    assert_select "#nav", { text: "Invoices", count: 0 }
    assert_select "#main.app-main"
    assert_select "td", "Acme Corp."
    assert_select ".app-pill", "Overdue"
  end

  private
    def sign_up_and_complete
      email_address = "owner-receivables@example.com"

      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }
    end
end
