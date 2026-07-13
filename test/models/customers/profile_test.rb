require "test_helper"

class Customers::ProfileTest < ActiveSupport::TestCase
  test "calculates payment behavior from paid and outstanding invoices" do
    as_of = Date.new(2026, 7, 11)
    invoices = [
      invoice(issued_on: Date.new(2026, 1, 1), due_on: Date.new(2026, 1, 31), paid_on: Date.new(2026, 1, 29), status: "PAID", total: 100, amount_due: 0, amount_paid: 100),
      invoice(issued_on: Date.new(2026, 3, 1), due_on: Date.new(2026, 3, 31), paid_on: Date.new(2026, 4, 10), status: "PAID", total: 200, amount_due: 0, amount_paid: 200),
      invoice(issued_on: Date.new(2026, 6, 1), due_on: Date.new(2026, 6, 30), total: 300, amount_due: 300)
    ]

    profile = Customers::Profile.new(invoices, identity: Customers::Profile.identity_for(invoices.first), as_of: as_of)

    assert_equal "Example Customer", profile.name
    assert_equal 3, profile.invoice_count
    assert_equal 2, profile.payment_history_count
    assert_equal 50, profile.on_time_rate
    assert_equal 4, profile.typical_days_from_due
    assert_equal 11, profile.oldest_overdue_days
    assert_equal "Established customer", profile.relationship_segment
    assert_equal "Limited payment history", profile.payment_segment
    assert_equal "Past due", profile.attention_segment
    assert_equal({ "INR" => 300.to_d }, profile.outstanding_totals)
    assert_equal({ "INR" => 600.to_d }, profile.total_billed_totals)
    assert_equal "Standard overdue follow-up", profile.reminder_recommendation.fetch(:name)
  end

  test "groups customers and assigns relative invoice value bands" do
    invoices = [
      invoice(contact_external_id: "small", contact_name: "Small Customer", total: 500, amount_due: 500),
      invoice(contact_external_id: "standard", contact_name: "Standard Customer", total: 5_000, amount_due: 5_000),
      invoice(contact_external_id: "large", contact_name: "Large Customer", total: 50_000, amount_due: 50_000),
      invoice(contact_external_id: "large", contact_name: "Large Customer", total: 40_000, amount_due: 40_000)
    ]

    profiles = Customers::Collection.new(invoices, as_of: Date.new(2026, 7, 11)).profiles.index_by(&:name)

    assert_equal 3, profiles.size
    assert_equal "Lower value", profiles.fetch("Small Customer").value_segment
    assert_equal "Standard value", profiles.fetch("Standard Customer").value_segment
    assert_equal "High value", profiles.fetch("Large Customer").value_segment
  end

  test "uses a normalized customer name when the provider has no contact id" do
    first = invoice(contact_external_id: nil, contact_name: "  Example   Customer ")
    second = invoice(contact_external_id: nil, contact_name: "example customer")

    profiles = Customers::Collection.new([ first, second ]).profiles

    assert_equal 1, profiles.size
    assert_equal 2, profiles.first.invoice_count
  end

  test "marks paid-up customers as requiring no reminder action" do
    paid = invoice(status: "PAID", amount_due: 0, amount_paid: 100, paid_on: Date.new(2026, 7, 10))

    profile = Customers::Collection.new([ paid ], as_of: Date.new(2026, 7, 11)).profiles.first

    assert_equal "No reminder needed", profile.reminder_recommendation.fetch(:name)
  end

  test "uses robust payment timing and flags unusual dates in collection forecasts" do
    as_of = Date.new(2026, 7, 11)
    invoices = [
      invoice(issued_on: Date.new(2026, 1, 1), due_on: Date.new(2026, 7, 31), paid_on: Date.new(2026, 1, 29), status: "PAID", total: 100, amount_due: 0, amount_paid: 100),
      invoice(issued_on: Date.new(2026, 2, 1), due_on: Date.new(2026, 2, 28), paid_on: Date.new(2026, 2, 28), status: "PAID", total: 100, amount_due: 0, amount_paid: 100),
      invoice(issued_on: Date.new(2026, 3, 1), due_on: Date.new(2026, 3, 31), paid_on: Date.new(2026, 3, 28), status: "PAID", total: 100, amount_due: 0, amount_paid: 100),
      invoice(issued_on: Date.new(2026, 7, 1), due_on: Date.new(2026, 7, 25), total: 250, amount_due: 250)
    ]

    profile = Customers::Profile.new(invoices, identity: Customers::Profile.identity_for(invoices.first), as_of: as_of)
    current_invoice = profile.outstanding_invoices.first

    assert_equal(-3, profile.typical_days_from_due)
    assert_equal(-2, profile.forecast_days_from_due)
    assert_equal 1, profile.unusual_payment_dates.size
    assert_equal Date.new(2026, 7, 23), profile.expected_collection_on(current_invoice)
    assert_equal Date.new(2026, 7, 22)..Date.new(2026, 7, 25), profile.expected_collection_window(current_invoice)
    assert_equal "Low", profile.forecast_confidence
    assert_equal 2, profile.comparable_payment_count
    assert_equal 2, profile.payment_history_events.size
  end

  test "falls back to the due date when a customer has no paid history" do
    outstanding = invoice(due_on: Date.new(2026, 7, 25), amount_due: 500)
    profile = Customers::Collection.new([ outstanding ], as_of: Date.new(2026, 7, 11)).profiles.first

    assert_equal Date.new(2026, 7, 25), profile.expected_collection_on(outstanding)
    assert_equal Date.new(2026, 7, 25)..Date.new(2026, 7, 25), profile.expected_collection_window(outstanding)
    assert_equal "Due date only", profile.forecast_confidence
    assert_equal "No paid history", profile.forecast_basis
  end

  private
    def invoice(contact_external_id: "contact-123", contact_name: "Example Customer", issued_on: Date.new(2026, 7, 1), due_on: Date.new(2026, 7, 31), paid_on: nil, status: "AUTHORISED", total: 100, amount_due: 100, amount_paid: 0)
      Invoice.new(
        invoice_source: invoice_sources(:xero),
        invoice_type: "ACCREC",
        external_id: SecureRandom.uuid,
        contact_external_id: contact_external_id,
        contact_name: contact_name,
        currency: "INR",
        issued_on: issued_on,
        due_on: due_on,
        paid_on: paid_on,
        status: status,
        total: total,
        amount_due: amount_due,
        amount_paid: amount_paid
      )
    end
end
