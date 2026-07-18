require "test_helper"

class InvoiceReminders::InvoiceFreshnessCheckTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
  end

  test "refreshes the target Xero invoice" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      @invoice.update!(synced_at: Time.current)
      @invoice.invoice_source.expects(:sync_invoice!)
        .with(external_id: @invoice.external_id)
        .returns(@invoice)

      assert_equal @invoice, InvoiceReminders::InvoiceFreshnessCheck.call(@invoice)
    end
  end

  test "refreshes the target Stripe invoice" do
    source = @invoice.account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "acct_freshness_check"
    )
    customer = source.customers.create!(
      account: @invoice.account,
      customer_segment: customer_segments(:normal_debtor_segment),
      external_id: "cus_freshness_check",
      name: "Stripe Customer",
      email: "stripe-customer@example.com"
    )
    invoice = source.invoices.create!(
      account: @invoice.account,
      customer:,
      external_id: "in_freshness_check",
      number: "STRIPE-FRESH",
      provider_status: "open",
      status: :open,
      currency: "USD",
      amount_due: 125,
      amount_paid: 0,
      total: 125,
      issued_on: Date.new(2026, 7, 1),
      due_on: Date.new(2026, 7, 31)
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      invoice.update!(synced_at: Time.current)
      source.expects(:sync_invoice!).with(external_id: invoice.external_id).returns(invoice)

      assert_equal invoice, InvoiceReminders::InvoiceFreshnessCheck.call(invoice)
    end
  end

  test "rejects a response that did not freshly update the invoice" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      @invoice.update!(synced_at: 1.hour.ago)
      @invoice.invoice_source.stubs(:sync_invoice!).returns(@invoice)

      assert_raises InvoiceReminders::InvoiceFreshnessCheck::Error do
        InvoiceReminders::InvoiceFreshnessCheck.call(@invoice)
      end
    end
  end
end
