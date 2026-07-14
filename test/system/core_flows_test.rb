require "application_system_test_case"

class CoreFlowsTest < ApplicationSystemTestCase
  test "signs up and reviews receivables through account settings" do
    sign_up
    account = Identity.find_by!(email_address: "system-flow@example.com").accounts.first
    create_invoice_history(account)

    click_link "Receivables"

    assert_text "Receivables"
    within "[data-testid='customer-inbox-row']" do
      assert_text "Harbor & Co"
      assert_text "USD 50,000"
      assert_selector ".app-invoice-status", text: "Overdue"
      assert_no_link "Harbor & Co"
    end

    click_link "Settings"

    assert_text "Xero"
    assert_text "Connected"
    click_button "Resync"
    assert_text "PaymentReminder Xero invoice resync started."

    click_button "Sign out"
    assert_text "Sign in"
  end

  private
    def sign_up
      visit new_signup_path
      fill_in "signup_email_address", with: "system-flow@example.com"
      click_button "Let's go"

      assert_text "Check your email"
      fill_in "code", with: MagicLink.order(:created_at).last.code
      click_button "Continue"

      assert_text "Complete your account"
      fill_in "signup_full_name", with: "System Flow"
      click_button "Continue"

      assert_text "Welcome to PaymentReminder."
      assert_text "Business profile"
    end

    def create_invoice_history(account)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "system-flow-tenant",
        external_account_name: "PaymentReminder Xero",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
      customer = source.customers.create!(
        account: account,
        external_id: "system-flow-contact",
        name: "Harbor & Co"
      )

      source.invoices.create!(
        account: account,
        customer: customer,
        external_id: "system-flow-overdue",
        number: "INV-SYSTEM-OVERDUE",
        invoice_type: "ACCREC",
        provider_status: "AUTHORISED",
        status: "open",
        currency: "USD",
        amount_due: 50_000,
        amount_paid: 0,
        total: 50_000,
        issued_on: Date.current - 60.days,
        due_on: Date.current - 40.days,
        contact_external_id: "system-flow-contact",
        contact_name: "Harbor & Co",
        synced_at: Time.current
      )

      source.invoices.create!(
        account: account,
        customer: customer,
        external_id: "system-flow-paid",
        number: "INV-SYSTEM-PAID",
        invoice_type: "ACCREC",
        provider_status: "PAID",
        status: "paid",
        currency: "USD",
        amount_due: 0,
        amount_paid: 5_000,
        total: 5_000,
        issued_on: Date.current - 40.days,
        due_on: Date.current - 20.days,
        paid_on: Date.current - 15.days,
        contact_external_id: "system-flow-contact",
        contact_name: "Harbor & Co",
        synced_at: Time.current
      )

      Receivable.refresh_for!(customer)
    end
end
