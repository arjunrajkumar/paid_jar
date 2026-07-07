require "test_helper"

class Invoices::RefreshJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "syncs the invoice from its source" do
    invoice = invoices(:xero_invoice)

    InvoiceSource.any_instance.expects(:sync_invoice!).with(external_id: invoice.external_id)

    Invoices::RefreshJob.perform_now(invoice)
  end

  test "skips invoice from disconnected source" do
    source = accounts(:paid_jar).invoice_sources.create!(
      provider: :stripe,
      status: :disconnected,
      external_account_id: "acct_disconnected"
    )
    invoice = source.invoices.create!(
      account: accounts(:paid_jar),
      external_id: "in_disconnected",
      number: "INV-DIS",
      currency: "USD"
    )

    InvoiceSource.any_instance.expects(:sync_invoice!).never

    Invoices::RefreshJob.perform_now(invoice)
  end

  test "still syncs invoice from errored source so retries can recover" do
    invoice = invoices(:xero_invoice)
    invoice.invoice_source.update!(status: :error, last_error: "provider unavailable")

    InvoiceSource.any_instance.expects(:sync_invoice!).with(external_id: invoice.external_id)

    Invoices::RefreshJob.perform_now(invoice)
  end

  test "retries provider sync failures" do
    invoice = invoices(:xero_invoice)
    InvoiceSource.any_instance.expects(:sync_invoice!).with(external_id: invoice.external_id).raises(InvoiceSources::Xero::OauthClient::Error, "provider unavailable")

    assert_enqueued_with(job: Invoices::RefreshJob) do
      Invoices::RefreshJob.perform_now(invoice)
    end
  end
end
