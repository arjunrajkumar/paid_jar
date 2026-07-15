require "test_helper"

class Account::SettingsControllerTest < ActionDispatch::IntegrationTest
  test "show renders simplified account settings" do
    account = sign_up_and_complete

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select "h1", "Settings"
    assert_select "#nav a[aria-current='page']", "Settings"
    assert_select ".app-card__title", "Business profile"
    assert_select ".app-field", account.name
    assert_select ".app-field", count: 1
    assert_select "body", { text: "owner-settings@example.com", count: 0 }
    assert_select "body", { text: "Billing email", count: 0 }
    assert_select "body", { text: "Currency", count: 0 }
    assert_select ".app-card__title", "Accounting integration"
    assert_select "a[href=?]", new_xero_connection_path, "Connect"
    assert_select "a[href=?]", new_stripe_connection_path, "Connect"
    assert_select ".app-card", count: 2
    assert_select "section", { text: "Reminder cadence", count: 0 }
    assert_select "section", { text: "Notifications", count: 0 }
    assert_select "form[action=?]", session_path(script_name: nil) do
      assert_select "button", "Sign out"
    end
  end

  test "connected invoice sources can be resynced" do
    account = sign_up_and_complete(email_address: "owner-settings-resync@example.com")
    source = account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "tenant-settings-resync",
      external_account_name: "PaymentReminder Xero",
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_at: 30.minutes.from_now
    )

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select ".app-pill", "Connected"
    assert_select "form[action=?]", invoice_source_refresh_path(source) do
      assert_select "button", "Resync"
    end
  end

  test "show renders customer segment rules" do
    account = sign_up_and_complete(email_address: "owner-segment-settings@example.com")

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select ".app-segment-rules-card" do
      assert_select ".app-card__title", "Customer segments"
      assert_select "th", "Segment"
      assert_select "th", "Current rule"
      assert_select "th", "Adjust rule"
      assert_select "tbody tr", count: 5
      assert_select "form[action=?]", account_settings_path(script_name: account.slug)
      assert_select "form[action=?]", account_customer_segment_refresh_path(script_name: account.slug) do
        assert_select "button", "Refresh segments"
      end
    end
  end

  test "update saves customer segment rules for the current account" do
    account = sign_up_and_complete(email_address: "owner-segment-update@example.com")
    other_account = Account.create!(name: "Other Segment Account")

    patch account_settings_url(script_name: account.slug), params: {
      account: {
        payer_segment_minimum_payment_history: 4,
        payer_segment_minimum_unreliable_history: 6,
        payer_segment_pays_on_time_rate: 85,
        payer_segment_unreliable_on_time_rate: 45,
        payer_segment_slow_payer_days: 10
      }
    }

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Customer segment rules saved. Refresh segments to apply them.", flash[:notice]
    assert_equal 4, account.reload.payer_segment_minimum_payment_history
    assert_equal 6, account.payer_segment_minimum_unreliable_history
    assert_equal 85, account.payer_segment_pays_on_time_rate
    assert_equal 45, account.payer_segment_unreliable_on_time_rate
    assert_equal 10, account.payer_segment_slow_payer_days
    assert_equal 3, other_account.reload.payer_segment_minimum_payment_history
  end

  test "update renders invalid customer segment rules" do
    account = sign_up_and_complete(email_address: "owner-segment-invalid@example.com")

    patch account_settings_url(script_name: account.slug), params: {
      account: {
        payer_segment_minimum_payment_history: 6,
        payer_segment_minimum_unreliable_history: 5,
        payer_segment_pays_on_time_rate: 80,
        payer_segment_unreliable_on_time_rate: 50,
        payer_segment_slow_payer_days: 7
      }
    }

    assert_response :unprocessable_entity
    assert_select "#flash", text: /Minimum unreliable history/
    assert_equal 3, account.reload.payer_segment_minimum_payment_history
  end

  test "sign out clears session" do
    account = sign_up_and_complete

    delete session_url(script_name: nil)

    assert_redirected_to new_session_url

    get account_settings_url(script_name: account.slug)

    assert_redirected_to new_session_url(script_name: nil)
  end

  private
    def sign_up_and_complete(email_address: "owner-settings@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end
