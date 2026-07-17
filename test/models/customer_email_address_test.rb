require "test_helper"

class CustomerEmailAddressTest < ActiveSupport::TestCase
  setup do
    @customer = customers(:xero_customer)
  end

  test "belongs to a customer and normalizes its email" do
    email_address = @customer.additional_email_addresses.create!(
      email: "  Accounts@Example.COM  "
    )

    assert_equal @customer, email_address.customer
    assert_equal "accounts@example.com", email_address.email
  end

  test "requires a valid email address" do
    email_address = @customer.additional_email_addresses.build(email: "not-an-email")

    assert_not email_address.valid?
    assert_includes email_address.errors[:email], "is invalid"
  end

  test "rejects an email address longer than a mailbox address" do
    email_address = @customer.additional_email_addresses.build(
      email: "#{"a" * 243}@example.com"
    )

    assert_not email_address.valid?
    assert_includes email_address.errors[:email], "is too long (maximum is 254 characters)"
  end

  test "keeps additional email addresses unique for each customer" do
    @customer.additional_email_addresses.create!(email: "accounts@example.com")
    duplicate = @customer.additional_email_addresses.build(email: " ACCOUNTS@EXAMPLE.COM ")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end

  test "does not duplicate the current synced email" do
    duplicate = @customer.additional_email_addresses.build(email: " CUSTOMER@EXAMPLE.COM ")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "is already the synced email"
  end
end
