require "test_helper"

class ReceivablesHelperTest < ActionView::TestCase
  include ReceivablesHelper

  test "maps each persisted receivable display status" do
    ReceivablesHelper::RECEIVABLE_STATUSES.each_key do |key|
      receivable = mock(display_status: key)

      assert_equal status(key), receivable_status(receivable)
    end
  end

  test "formats persisted totals by currency" do
    rendered_totals = receivable_totals({ "USD" => "125.00", "EUR" => "50.00" }).to_s

    assert_includes rendered_totals, "EUR 50"
    assert_includes rendered_totals, "USD 125"
    assert_operator rendered_totals.index("EUR"), :<, rendered_totals.index("USD")
  end

  private
    def status(key)
      ReceivablesHelper::RECEIVABLE_STATUSES.fetch(key)
    end
end
