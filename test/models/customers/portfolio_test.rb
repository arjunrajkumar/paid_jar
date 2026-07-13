require "test_helper"

class Customers::PortfolioTest < ActiveSupport::TestCase
  test "separates upcoming expected cash from invoices past their expected date" do
    as_of = Date.new(2026, 7, 11)
    source = invoice_sources(:xero)
    upcoming = invoice(source, contact_id: "upcoming", customer: "Upcoming Customer", due_on: Date.new(2026, 7, 25), amount_due: 1_000)
    missed = invoice(source, contact_id: "missed", customer: "Missed Customer", due_on: Date.new(2026, 7, 1), amount_due: 2_000)
    later = invoice(source, contact_id: "later", customer: "Later Customer", due_on: Date.new(2026, 9, 1), amount_due: 3_000)

    profiles = Customers::Collection.new([ upcoming, missed, later ], as_of: as_of).profiles
    portfolio = Customers::Portfolio.new(profiles, as_of: as_of)

    assert_equal({ "INR" => 1_000.to_d }, portfolio.expected_next_30_days_totals)
    assert_equal({ "INR" => 2_000.to_d }, portfolio.past_expected_totals)
    assert_equal 1, portfolio.past_expected_invoices.size
    assert_equal "Review overdue balance", portfolio.priorities.first.fetch(:action)
    assert_equal "Missed Customer", portfolio.priorities.first.fetch(:customer).name
    assert_equal [ "Missed Customer" ], portfolio.today_priorities.map { |priority| priority.fetch(:customer).name }
    assert_equal({ "INR" => 2_000.to_d }, portfolio.today_priority_totals)
  end

  private
    def invoice(source, contact_id:, customer:, due_on:, amount_due:)
      Invoice.new(
        invoice_source: source,
        invoice_type: "ACCREC",
        external_id: SecureRandom.uuid,
        contact_external_id: contact_id,
        contact_name: customer,
        currency: "INR",
        issued_on: due_on - 30.days,
        due_on: due_on,
        status: "AUTHORISED",
        total: amount_due,
        amount_due: amount_due,
        amount_paid: 0
      )
    end
end
