require "test_helper"

class CustomersControllerTest < ActionDispatch::IntegrationTest
  test "index redirects to the canonical customer inbox" do
    account = sign_up_and_complete

    get customers_url(script_name: account.slug)

    assert_redirected_to home_url(script_name: account.slug)
  end

  test "show presents customer payment intelligence and invoice history" do
    account = sign_up_and_complete(email_address: "owner-customer-show@example.com")
    source = create_invoice_source(account)
    paid = create_invoice(
      source,
      external_id: "harbor-paid",
      contact_external_id: "harbor",
      customer: "Harbor & Co",
      amount_due: 0,
      amount_paid: 1_200,
      total: 1_200,
      status: "PAID",
      issued_on: Date.new(2026, 1, 1),
      due_on: Date.new(2026, 1, 31),
      paid_on: Date.new(2026, 2, 5)
    )
    create_invoice(
      source,
      external_id: "harbor-overdue",
      contact_external_id: "harbor",
      customer: "Harbor & Co",
      amount_due: 950,
      issued_on: Date.new(2026, 3, 1),
      due_on: Date.new(2026, 3, 31)
    )
    create_invoice(source, external_id: "other", contact_external_id: "other", customer: "Other Customer", amount_due: 500)

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(Customers::Profile.to_param_for(paid), script_name: account.slug)
    end

    assert_response :success
    assert_select "h1", "Harbor & Co"
    assert_select "[data-testid='customer-outstanding']", text: /INR 950/
    assert_select "[data-testid='customer-total-billed']", text: /INR 2,150/
    assert_select "[data-testid='customer-payment-timing']", text: "5 days late"
    assert_select "[data-testid='customer-expected-collection']", text: "Apr 2-8, 2026"
    assert_select "[data-testid='customer-on-time-rate']", text: "0%"
    assert_select "[data-testid='customer-recommendation']", text: /Review this account today/
    assert_select "[data-testid='customer-recommendation']", text: /Firm overdue follow-up/
    assert_select "#open-invoices", text: /HARBOR-OVERDUE/
    assert_select "#customer-invoices tbody tr", 2
    assert_select "[data-testid='payment-history-event']", 1
    assert_select "body", { text: "Other Customer", count: 0 }
  end

  test "show isolates unusual payment dates from the main payment pattern" do
    account = sign_up_and_complete(email_address: "owner-customer-anomaly@example.com")
    source = create_invoice_source(account)
    unusual = create_invoice(source, external_id: "unusual", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "PAID", issued_on: Date.new(2026, 1, 1), due_on: Date.new(2026, 7, 31), paid_on: Date.new(2026, 1, 29))
    create_invoice(source, external_id: "typical-1", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "PAID", issued_on: Date.new(2026, 2, 1), due_on: Date.new(2026, 2, 28), paid_on: Date.new(2026, 2, 28))
    create_invoice(source, external_id: "typical-2", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "PAID", issued_on: Date.new(2026, 3, 1), due_on: Date.new(2026, 3, 31), paid_on: Date.new(2026, 3, 28))
    create_invoice(source, external_id: "current", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 250, due_on: Date.new(2026, 7, 25))

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(Customers::Profile.to_param_for(unusual), script_name: account.slug)
    end

    assert_response :success
    assert_select "[data-testid='data-quality-warning']", text: /183 days before its due date/
    assert_select "[data-testid='payment-history-event']", 2
    assert_select "#invoice-#{unusual.id} .app-pill", "Check data"
    assert_select "[data-testid='customer-expected-collection']", text: "Jul 22-25, 2026"
    assert_select "body", { text: "183 days early", count: 0 }
  end

  test "show does not expose another account customer" do
    account = sign_up_and_complete(email_address: "owner-customer-scope@example.com")
    other_account = Account.create_with_owner(
      account: { name: "Other Account" },
      owner: { identity: Identity.create!(email_address: "other-customer@example.com"), name: "Other Owner" }
    )
    other_source = create_invoice_source(other_account)
    other_invoice = create_invoice(other_source, external_id: "private", contact_external_id: "private", customer: "Private Customer", amount_due: 500)

    get customer_url(Customers::Profile.to_param_for(other_invoice), script_name: account.slug)

    assert_response :not_found
  end

  private
    def create_invoice_source(account)
      account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "tenant-#{account.id}",
        external_account_name: "PaymentReminder Xero",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
    end

    def create_invoice(source, external_id:, contact_external_id:, customer:, amount_due:, issued_on: Date.new(2026, 7, 1), due_on: Date.new(2026, 7, 31), paid_on: nil, status: "AUTHORISED", amount_paid: 0, total: nil)
      source.invoices.create!(
        account: source.account,
        external_id: external_id,
        number: external_id.upcase,
        invoice_type: "ACCREC",
        contact_external_id: contact_external_id,
        contact_name: customer,
        status: status,
        currency: "INR",
        total: total || amount_due,
        amount_due: amount_due,
        amount_paid: amount_paid,
        issued_on: issued_on,
        due_on: due_on,
        paid_on: paid_on
      )
    end

    def sign_up_and_complete(email_address: "owner-customers@example.com")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end
