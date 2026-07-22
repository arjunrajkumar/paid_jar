require "test_helper"

class Madmin::ImpersonationsControllerTest < ActionDispatch::IntegrationTest
  test "platform admin can act as an active user and stop" do
    sign_up_and_complete(email_address: "platform-impersonator@example.com")
    target_account = Account.create_with_owner(
      account: { name: "Target Company" },
      owner: {
        name: "Target Owner",
        identity: Identity.create!(email_address: "target-owner@example.com")
      }
    )
    target_user = target_account.users.owner.sole
    PlatformAdminAccess.stubs(:allowed?).returns(true)

    post impersonate_madmin_user_url(target_user)

    assert_redirected_to invoices_url(script_name: target_account.slug)
    follow_redirect!
    assert_response :success
    assert_select "aside", text: /Platform admin: acting as Target Owner in Target Company/
    assert_select "form[action=?]", madmin_impersonation_path(script_name: nil) do
      assert_select "button", "Stop acting as user"
    end

    delete madmin_impersonation_url(script_name: nil)

    assert_redirected_to madmin_root_url(script_name: nil)
    follow_redirect!
    assert_response :success
    assert_select "aside", text: /Platform admin: acting as/, count: 0
  end

  test "rejects impersonating inactive and system users" do
    account = sign_up_and_complete(email_address: "platform-invalid-target@example.com")
    PlatformAdminAccess.stubs(:allowed?).returns(true)
    inactive_user = account.users.owner.sole
    inactive_user.update!(active: false)

    post impersonate_madmin_user_url(inactive_user)
    assert_redirected_to madmin_user_url(inactive_user)

    post impersonate_madmin_user_url(account.users.find_by!(role: :system))
    assert_redirected_to madmin_user_url(account.users.find_by!(role: :system))
  end

  test "ordinary users cannot start impersonation" do
    account = sign_up_and_complete(email_address: "ordinary-impersonator@example.com")

    post impersonate_madmin_user_url(account.users.owner.sole)

    assert_redirected_to root_url(script_name: nil)
  end

  private
    def sign_up_and_complete(email_address:)
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Platform Admin" } }

      Identity.find_by!(email_address:).accounts.first
    end
end
