require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  def parse(html)
    Nokogiri::HTML::DocumentFragment.parse(html)
  end

  test "page title tag without page title or account" do
    Current.account = nil

    assert_select parse(page_title_tag), "title", text: "PaymentReminder"
  end

  test "page title tag with page title" do
    Current.account = nil
    @page_title = "Account Settings"

    assert_select parse(page_title_tag), "title", text: "Account Settings | PaymentReminder"
  end

  test "page title tag with page title and account" do
    Current.account = accounts(:paid_jar)
    @page_title = "Account Settings"

    assert_select parse(page_title_tag), "title", text: "Account Settings | PaymentReminder"
  ensure
    Current.reset
  end
end
