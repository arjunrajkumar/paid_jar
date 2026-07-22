require "test_helper"

class InvoiceSources::RefreshAllJobTest < ActiveJob::TestCase
  test "enqueues active and recoverable errored invoice sources" do
    active_source = invoice_sources(:xero)
    errored_source = create_source(
      provider: :stripe,
      status: :error,
      external_account_id: "acct_refresh_recovery"
    )

    assert_enqueued_jobs 2, only: InvoiceSources::RefreshJob do
      InvoiceSources::RefreshAllJob.perform_now
    end

    assert_enqueued_with(job: InvoiceSources::RefreshJob, args: [ active_source ])
    assert_enqueued_with(job: InvoiceSources::RefreshJob, args: [ errored_source ])
  end

  test "does not enqueue pending disconnected or unrecoverable invoice sources" do
    invoice_sources(:xero).update!(status: :disconnected)
    create_source(
      provider: :stripe,
      status: :pending,
      external_account_id: "acct_refresh_pending"
    )
    create_source(
      provider: :stripe,
      status: :disconnected,
      external_account_id: "acct_refresh_disconnected"
    )
    create_source(
      provider: :xero,
      status: :error,
      external_account_id: "tenant_refresh_without_token"
    )

    assert_no_enqueued_jobs only: InvoiceSources::RefreshJob do
      InvoiceSources::RefreshAllJob.perform_now
    end
  end

  private
    def create_source(provider:, status:, external_account_id:, refresh_token: nil)
      Account.create!(name: "#{external_account_id} Account").invoice_sources.create!(
        provider:,
        status:,
        external_account_id:,
        refresh_token:
      )
    end
end
