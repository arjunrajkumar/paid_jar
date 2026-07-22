require "test_helper"

class InvoiceSources::RefreshJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "syncs invoices for the source" do
    InvoiceSource.any_instance.expects(:sync_invoices!)

    InvoiceSources::RefreshJob.perform_now(invoice_sources(:xero))
  end

  test "skips disconnected source" do
    source = accounts(:paid_jar).invoice_sources.create!(
      provider: :stripe,
      status: :disconnected,
      external_account_id: "acct_disconnected"
    )

    InvoiceSource.any_instance.expects(:sync_invoices!).never

    InvoiceSources::RefreshJob.perform_now(source)
  end

  test "still syncs errored source so retries can recover" do
    source = invoice_sources(:xero)
    source.update!(status: :error, last_error: "provider unavailable")

    InvoiceSource.any_instance.expects(:sync_invoices!)

    InvoiceSources::RefreshJob.perform_now(source)
  end

  test "skips a pending source" do
    source = Account.create!(name: "Pending Refresh").invoice_sources.create!(
      provider: :stripe,
      status: :pending,
      external_account_id: "acct_pending_refresh"
    )

    InvoiceSource.any_instance.expects(:sync_invoices!).never

    InvoiceSources::RefreshJob.perform_now(source)
  end

  test "skips an errored source without the credentials required to recover" do
    source = Account.create!(name: "Unrecoverable Refresh").invoice_sources.create!(
      provider: :xero,
      status: :error,
      external_account_id: "tenant_unrecoverable_refresh"
    )

    InvoiceSource.any_instance.expects(:sync_invoices!).never

    InvoiceSources::RefreshJob.perform_now(source)
  end

  test "retries provider sync failures" do
    InvoiceSource.any_instance.expects(:sync_invoices!).raises(InvoiceSources::Xero::OauthClient::Error, "provider unavailable")

    assert_enqueued_with(job: InvoiceSources::RefreshJob) do
      InvoiceSources::RefreshJob.perform_now(invoice_sources(:xero))
    end
  end
end
