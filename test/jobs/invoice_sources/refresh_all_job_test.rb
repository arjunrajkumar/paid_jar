require "test_helper"

class InvoiceSources::RefreshAllJobTest < ActiveJob::TestCase
  test "refreshes every connected invoice source" do
    connected_source = mock(connected?: true)

    InvoiceSource.expects(:find_each).yields(connected_source)
    InvoiceSources::RefreshJob.expects(:perform_later).with(connected_source)

    InvoiceSources::RefreshAllJob.perform_now
  end

  test "does not refresh a disconnected invoice source" do
    disconnected_source = mock(connected?: false)

    InvoiceSource.expects(:find_each).yields(disconnected_source)
    InvoiceSources::RefreshJob.expects(:perform_later).never

    InvoiceSources::RefreshAllJob.perform_now
  end
end
