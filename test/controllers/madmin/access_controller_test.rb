require "test_helper"

class Madmin::AccessControllerTest < ActionDispatch::IntegrationTest
  test "requires a signed in identity" do
    get madmin_root_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "rejects an ordinary account owner" do
    sign_up_and_complete(email_address: "ordinary-owner@example.com")

    get madmin_root_url

    assert_redirected_to root_url(script_name: nil)
    assert_equal "You do not have platform administrator access.", flash[:alert]
  end

  test "allows a configured platform administrator" do
    sign_up_and_complete(email_address: "platform-owner@example.com")
    PlatformAdminAccess.stubs(:allowed?).returns(true)

    get madmin_root_url

    assert_response :success
    assert_select "h1", text: /Dashboard/i
  end

  test "redirects an account-scoped admin request to the global admin panel" do
    account = sign_up_and_complete(email_address: "scoped-platform-owner@example.com")
    PlatformAdminAccess.stubs(:allowed?).returns(true)

    get madmin_root_url(script_name: account.slug)

    assert_redirected_to madmin_root_url(script_name: nil)
    assert_response :see_other
  end

  private
    def sign_up_and_complete(email_address:)
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Platform Admin" } }

      Identity.find_by!(email_address:).accounts.first
    end
end
