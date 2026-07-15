require "application_system_test_case"

class CustomerSegmentRulesTest < ApplicationSystemTestCase
  test "history rules disable contradictory choices without changing values" do
    sign_up_and_complete

    assert_enabled_options "account_payer_segment_minimum_payment_history", 1..5
    assert_enabled_options "account_payer_segment_minimum_unreliable_history", 3..12

    select "10 payments", from: "account_payer_segment_minimum_unreliable_history"

    assert_select_field "account_payer_segment_minimum_payment_history", selected: "3 payments"
    assert_enabled_options "account_payer_segment_minimum_payment_history", 1..10
  end

  test "on-time rules disable contradictory choices without changing values" do
    sign_up_and_complete

    assert_enabled_options "account_payer_segment_pays_on_time_rate", (55..100).step(5)
    assert_enabled_options "account_payer_segment_unreliable_on_time_rate", (0..75).step(5)

    select "70%", from: "account_payer_segment_unreliable_on_time_rate"

    assert_select_field "account_payer_segment_pays_on_time_rate", selected: "80% or more"
    assert_enabled_options "account_payer_segment_pays_on_time_rate", (75..100).step(5)
  end


  private
    def sign_up_and_complete
      visit new_signup_path
      fill_in "signup_email_address", with: "segment-rules-system@example.com"
      click_button "Let's go"

      fill_in "code", with: MagicLink.order(:created_at).last.code
      click_button "Continue"

      fill_in "signup_full_name", with: "Segment Rules"
      click_button "Continue"

      click_link "Settings"
    end

    def assert_enabled_options(field_id, expected_values)
      options = find("##{field_id}").all("option", disabled: false).map { |option| option.value.to_i }

      assert_equal expected_values.to_a, options
    end
end
