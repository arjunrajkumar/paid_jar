require "test_helper"

class Customers::EmailAddressesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = sign_up_and_complete
    @source = create_invoice_source(@account)
    @customer = @source.customers.create!(
      account: @account,
      external_id: "customer-reminder-recipients",
      name: "Acme Customer",
      email: "billing@acme.example"
    )
  end

  test "index requires a PaymentReminder session" do
    delete session_url(script_name: nil)

    get customer_email_addresses_url(@customer, script_name: @account.slug)

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "index shows the synced and additional reminder recipients" do
    @customer.additional_email_addresses.create!(email: "owner@acme.example")

    get customer_email_addresses_url(@customer, script_name: @account.slug)

    assert_response :success
    assert_select "h1", "Reminder recipients"
    assert_select "[data-testid='recipient-customer-name']", "Acme Customer"
    assert_select "[data-testid='synced-email-address']", "billing@acme.example"
    assert_select "[data-testid='synced-email-source']", text: /Xero/
    assert_select "[data-testid='additional-email-address']", "owner@acme.example"
    assert_select "form[action=?]", customer_email_addresses_path(@customer, script_name: @account.slug) do
      assert_select "input[name='customer_email_address[email]'][type='email'][maxlength='254']"
      assert_select "input[type='submit'][value='Add email']"
    end
  end

  test "index warns when the provider supplied an unusable email" do
    @customer.update_column(:email, "not-an-email")

    get customer_email_addresses_url(@customer, script_name: @account.slug)

    assert_response :success
    assert_select "[data-testid='invalid-synced-email-address']", "not-an-email"
    assert_select "[data-testid='invalid-synced-email-warning']", text: /will not receive reminders/
    assert_select "[data-testid='synced-email-included']", count: 0
  end

  test "create adds a normalized email address to the customer" do
    assert_difference -> { @customer.additional_email_addresses.count }, 1 do
      post customer_email_addresses_url(@customer, script_name: @account.slug), params: {
        customer_email_address: { email: "  Owner@Acme.Example " }
      }
    end

    assert_redirected_to customer_email_addresses_url(@customer, script_name: @account.slug)
    assert_equal "Recipient added.", flash[:notice]
    assert_equal "owner@acme.example", @customer.additional_email_addresses.last.email
  end

  test "create explains an invalid email without saving it" do
    assert_no_difference -> { @customer.additional_email_addresses.count } do
      post customer_email_addresses_url(@customer, script_name: @account.slug), params: {
        customer_email_address: { email: "not-an-email" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /Email is invalid/
  end

  test "destroy removes an additional email address" do
    email_address = @customer.additional_email_addresses.create!(email: "owner@acme.example")

    assert_difference -> { @customer.additional_email_addresses.count }, -1 do
      delete customer_email_address_url(@customer, email_address, script_name: @account.slug)
    end

    assert_redirected_to customer_email_addresses_url(@customer, script_name: @account.slug)
    assert_equal "Recipient removed.", flash[:notice]
  end

  test "customers and email addresses are scoped to the current account" do
    other_account = Account.create!(name: "Other Recipient Account")
    other_source = create_invoice_source(other_account, external_account_id: "other-recipient-source")
    other_customer = other_source.customers.create!(
      account: other_account,
      external_id: "other-customer",
      name: "Other Customer"
    )
    other_email_address = other_customer.additional_email_addresses.create!(email: "other@example.com")

    get customer_email_addresses_url(other_customer, script_name: @account.slug)
    assert_response :not_found

    post customer_email_addresses_url(other_customer, script_name: @account.slug), params: {
      customer_email_address: { email: "intruder@example.com" }
    }
    assert_response :not_found

    delete customer_email_address_url(other_customer, other_email_address, script_name: @account.slug)
    assert_response :not_found
    assert_predicate other_email_address.reload, :persisted?
  end

  private
    def create_invoice_source(account, external_account_id: "customer-recipient-source")
      account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id:
      )
    end

    def sign_up_and_complete
      email_address = "recipient-owner-#{SecureRandom.hex(4)}@example.com"

      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Recipient Owner" } }

      Identity.find_by!(email_address:).accounts.first
    end
end
