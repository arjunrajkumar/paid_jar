require "test_helper"

class AccountScopingControllerTest < ActionDispatch::IntegrationTest
  test "an account-scoped request uses the membership for that exact account" do
    first_account = sign_up_and_complete
    second_account = add_account(first_account.users.owner.sole.identity, name: "Second Business")

    get account_settings_url(script_name: second_account.slug)

    assert_response :success
    assert_select ".app-field", "Second Business"
    assert_select ".app-field", { text: first_account.name, count: 0 }
  end

  test "an inaccessible account scope is rejected" do
    sign_up_and_complete(email_address: "scoping-inaccessible@example.com")
    inaccessible_account = Account.create!(name: "Private Business")

    get account_settings_url(script_name: inaccessible_account.slug)

    assert_redirected_to root_url(script_name: nil)
  end

  test "a nonexistent account scope is rejected" do
    sign_up_and_complete(email_address: "scoping-missing@example.com")
    nonexistent_external_id = Account.maximum(:external_account_id) + 10_000

    get account_settings_url(script_name: "/#{nonexistent_external_id}")

    assert_redirected_to root_url(script_name: nil)
  end

  private
    def sign_up_and_complete(email_address: "scoping-owner@example.com")
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Scoping Owner" } }

      Identity.find_by!(email_address:).accounts.first
    end

    def add_account(identity, name:)
      Account.create_with_owner(
        account: { name: },
        owner: { name: "Scoping Owner", identity: }
      )
    end
end
