require "test_helper"

class EmailConnections::PollInboundJobTest < ActiveJob::TestCase
  test "fans out only to active inbound-ready Gmail connections" do
    connection = email_connections(:paid_jar_gmail)

    assert_enqueued_with(
      job: EmailConnections::SyncInboundJob,
      args: [
        connection.id,
        connection.provider_account_id,
        connection.credential_generation
      ]
    ) do
      EmailConnections::PollInboundJob.perform_now
    end

    clear_enqueued_jobs
    assert_no_enqueued_jobs only: EmailConnections::SyncInboundJob do
      EmailConnections::PollInboundJob.perform_now
    end

    connection.update_columns(inbound_sync_job_id: nil, inbound_sync_enqueued_at: nil)
    connection.update_columns(scopes: [ EmailConnection::Gmailable::SEND_SCOPE ])
    assert_no_enqueued_jobs only: EmailConnections::SyncInboundJob do
      EmailConnections::PollInboundJob.perform_now
    end
  end
end
