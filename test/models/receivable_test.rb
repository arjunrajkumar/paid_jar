require "test_helper"

class ReceivableTest < ActiveSupport::TestCase
  setup do
    @source = invoice_sources(:xero)
    @customer = @source.customers.create!(
      account: @source.account,
      external_id: SecureRandom.uuid,
      name: "Receivable Customer"
    )
    @invoice_sequence = 0
  end

  test "creates and refreshes one persistent row with one invoice query" do
    invoice(status: "pending")

    assert_difference -> { Receivable.count }, 1 do
      assert_queries_match(/FROM [`"]invoices[`"]/, count: 1) do
        @receivable = Receivable.refresh_for!(@customer)
      end
    end

    assert_predicate @receivable, :status_none?
    assert_predicate @receivable, :payer_segment_new?
    assert_empty @receivable.outstanding_totals
    assert_empty @receivable.uncollectible_totals
    assert_equal 0, @receivable.open_invoice_count
    assert_equal 0, @receivable.outstanding_invoice_count
    assert_equal 0, @receivable.uncollectible_invoice_count
    assert_not_nil @receivable.calculated_at
    assert_not_includes Receivable.active, @receivable

    assert_no_difference -> { Receivable.count } do
      assert_equal @receivable, Receivable.refresh_for!(@customer)
    end
  end

  test "requires a unique customer from the same account" do
    receivable = Receivable.refresh_for!(@customer)
    duplicate = Receivable.new(account: @customer.account, customer: @customer)
    other_account = Account.create!(name: "Other Account")
    mismatched = Receivable.new(account: other_account, customer: @customer)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:customer_id], "has already been taken"
    assert_not mismatched.valid?
    assert_includes mismatched.errors[:account], "must match customer account"
    assert_equal receivable, @customer.reload.receivable
    assert_equal [ receivable ], @customer.account.receivables.reload.to_a
  end

  test "summarizes issued invoices by status currency and earliest due date" do
    invoice(status: "paid", amount_due: 0, amount_paid: 200, due_on: Date.new(2026, 5, 1), paid_on: Date.new(2026, 5, 1))
    invoice(status: "pending", amount_due: 900, due_on: Date.new(2026, 5, 2))
    invoice(status: "open", amount_due: 100, due_on: Date.new(2026, 7, 20), currency: "INR")
    invoice(status: "open", amount_due: 25.5, due_on: Date.new(2026, 7, 10), currency: "USD")
    invoice(status: "open", amount_due: 0, due_on: Date.new(2026, 7, 1), currency: "INR")
    invoice(status: "uncollectible", amount_due: 75, due_on: Date.new(2026, 6, 1), currency: "INR")

    receivable = Receivable.refresh_for!(@customer)

    assert_predicate receivable, :status_outstanding?
    assert_equal Date.new(2026, 7, 10), receivable.due_on
    assert_equal({ "INR" => "100.00", "USD" => "25.50" }, receivable.outstanding_totals)
    assert_equal({ "INR" => "75.00" }, receivable.uncollectible_totals)
    assert_equal 3, receivable.open_invoice_count
    assert_equal 2, receivable.outstanding_invoice_count
    assert_equal 1, receivable.uncollectible_invoice_count
    assert_includes Receivable.active, receivable
  end

  test "uses outstanding uncollectible open paid and none precedence" do
    paid = invoice(status: "paid", amount_due: 0, amount_paid: 100, paid_on: Date.new(2026, 7, 1))
    receivable = Receivable.refresh_for!(@customer)
    assert_predicate receivable, :status_paid?

    open_without_balance = invoice(status: "open", amount_due: 0)
    receivable = Receivable.refresh_for!(@customer)
    assert_predicate receivable, :status_open?

    uncollectible = invoice(status: "uncollectible", amount_due: 100)
    receivable = Receivable.refresh_for!(@customer)
    assert_predicate receivable, :status_uncollectible?

    outstanding = invoice(status: "open", amount_due: 50)
    receivable = Receivable.refresh_for!(@customer)
    assert_predicate receivable, :status_outstanding?

    [ paid, open_without_balance, uncollectible, outstanding ].each { |record| record.update!(status: :void) }
    receivable = Receivable.refresh_for!(@customer)
    assert_predicate receivable, :status_none?
  end

  test "derives overdue display status from the requested date" do
    invoice(status: "open", amount_due: 100, due_on: Date.new(2026, 7, 10))
    receivable = Receivable.refresh_for!(@customer)

    assert_not receivable.overdue?(as_of: Date.new(2026, 7, 10))
    assert_equal :outstanding, receivable.display_status(as_of: Date.new(2026, 7, 10))
    assert receivable.overdue?(as_of: Date.new(2026, 7, 11))
    assert_equal :overdue, receivable.display_status(as_of: Date.new(2026, 7, 11))
  end

  test "classifies customers with limited payment history as new" do
    assert_equal "new", segment_after_payments(0, 0)
  end

  test "classifies any recent uncollectible invoice as unreliable" do
    invoice(status: "uncollectible", amount_due: 100, due_on: next_due_on)

    assert_equal "unreliable_payer", refreshed_segment
  end

  test "classifies customers that reliably pay by the due date" do
    assert_equal "pays_on_time", segment_after_payments(-1, 0, 0)
  end

  test "classifies customers with mixed timing as sometimes late" do
    assert_equal "sometimes_late", segment_after_payments(0, 3, 7)
  end

  test "classifies customers whose typical payment is late as slow payers" do
    assert_equal "slow_payer", segment_after_payments(8, 9, 10)
  end

  test "classifies a long and inconsistent late history as unreliable" do
    assert_equal "unreliable_payer", segment_after_payments(0, 8, 10, 20, 25)
  end

  test "uses only the latest twelve eligible payment outcomes" do
    older_due_on = Date.new(2024, 12, 20)
    invoice(
      status: "uncollectible",
      amount_due: 100,
      issued_on: older_due_on - 20.days,
      due_on: older_due_on
    )

    12.times do |month|
      due_on = Date.new(2025, month + 1, 20)
      paid_invoice(delay: 0, due_on: due_on)
    end

    invoice(
      status: "paid",
      amount_due: 0,
      amount_paid: 100,
      issued_on: Date.new(2026, 1, 1),
      due_on: nil,
      paid_on: Date.new(2026, 1, 20)
    )

    assert_equal "pays_on_time", refreshed_segment
  end

  test "keeps an unusual early payment from changing an on-time segment" do
    paid_invoice(delay: -183, due_on: Date.new(2026, 7, 31))
    paid_invoice(delay: 0, due_on: Date.new(2026, 2, 28))
    paid_invoice(delay: -3, due_on: Date.new(2026, 3, 31))

    assert_equal "pays_on_time", refreshed_segment
  end

  test "uses the account minimum payment history" do
    @customer.account.update!(payer_segment_minimum_payment_history: 4)

    assert_equal "new", segment_after_payments(0, 0, 0)
  end

  test "uses the account pays-on-time rate" do
    @customer.account.update!(payer_segment_pays_on_time_rate: 65)

    assert_equal "pays_on_time", segment_after_payments(0, 0, 5)
  end

  test "uses the account slow-payer delay" do
    @customer.account.update!(payer_segment_slow_payer_days: 10)

    assert_equal "sometimes_late", segment_after_payments(8, 9, 10)
  end

  test "uses the account minimum unreliable history" do
    @customer.account.update!(payer_segment_minimum_unreliable_history: 6)

    assert_equal "slow_payer", segment_after_payments(0, 8, 10, 20, 25)
  end

  test "uses the account unreliable on-time rate" do
    @customer.account.update!(payer_segment_unreliable_on_time_rate: 40)

    assert_equal "slow_payer", segment_after_payments(0, 0, 10, 20, 25)
  end

  test "refreshes every customer for one account" do
    account = Account.create!(name: "Segment Refresh Account")
    source = account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "segment-refresh-source"
    )
    customer = source.customers.create!(
      account: account,
      external_id: "segment-refresh-customer",
      name: "Segment Refresh Customer"
    )

    Receivable.expects(:refresh_for!).with(customer)

    Receivable.refresh_for_account!(account)
  end

  private
    def segment_after_payments(*payment_delays)
      payment_delays.each { |delay| paid_invoice(delay:) }
      refreshed_segment
    end

    def refreshed_segment
      Receivable.refresh_for!(@customer).payer_segment
    end

    def paid_invoice(delay:, due_on: next_due_on)
      invoice(
        status: "paid",
        issued_on: due_on - 30.days,
        due_on: due_on,
        paid_on: due_on + delay.days,
        amount_due: 0,
        amount_paid: 100
      )
    end

    def next_due_on
      @invoice_sequence += 1
      Date.new(2025, 1, 31) + @invoice_sequence.months
    end

    def invoice(
      status: "open",
      issued_on: Date.new(2026, 7, 1),
      due_on: Date.new(2026, 7, 31),
      paid_on: nil,
      amount_due: 100,
      amount_paid: 0,
      currency: "INR"
    )
      @customer.invoices.create!(
        account: @customer.account,
        invoice_source: @source,
        invoice_type: "ACCREC",
        external_id: SecureRandom.uuid,
        contact_external_id: @customer.external_id,
        contact_name: @customer.name,
        currency: currency,
        issued_on: issued_on,
        due_on: due_on,
        paid_on: paid_on,
        provider_status: status,
        status: status,
        total: amount_due + amount_paid,
        amount_due: amount_due,
        amount_paid: amount_paid
      )
    end
end
