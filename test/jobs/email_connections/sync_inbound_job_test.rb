require "test_helper"

class EmailConnections::SyncInboundJobTest < ActiveJob::TestCase
  setup do
    @connection = email_connections(:paid_jar_gmail)
    @provider_account_id = @connection.provider_account_id
    @credential_generation = @connection.credential_generation
  end

  test "enqueue reserves one sync job for the credential generation" do
    assert_enqueued_jobs 1, only: EmailConnections::SyncInboundJob do
      assert EmailConnections::SyncInboundJob.enqueue(@connection)
      assert_not EmailConnections::SyncInboundJob.enqueue(@connection)
    end

    assert @connection.reload.inbound_sync_job_id
    assert @connection.inbound_sync_enqueued_at
  end

  test "an enqueue failure releases the sync reservation" do
    ActiveJob::Base.queue_adapter.stubs(:enqueue).raises(RuntimeError, "queue unavailable")

    assert_raises RuntimeError do
      EmailConnections::SyncInboundJob.enqueue(@connection)
    end

    assert_nil @connection.reload.inbound_sync_job_id
    assert_nil @connection.inbound_sync_enqueued_at
  end

  test "a successful sync releases its reservation" do
    EmailConnection::Gmail::Synchronizer.expects(:call).returns([])

    EmailConnections::SyncInboundJob.perform_now(
      @connection.id,
      @provider_account_id,
      @credential_generation
    )

    assert_nil @connection.reload.inbound_sync_job_id
    assert_nil @connection.inbound_sync_enqueued_at
  end

  test "a credential replacement cancels cleanly without a failed job" do
    EmailConnection::Gmail::Synchronizer.stubs(:call)
      .raises(EmailConnection::Errors::CredentialChanged, "email_connection_credentials_changed")

    assert_nothing_raised do
      EmailConnections::SyncInboundJob.perform_now(
        @connection.id,
        @provider_account_id,
        @credential_generation
      )
    end

    assert_nil @connection.reload.inbound_sync_job_id
  end

  test "a temporary provider failure keeps one reservation for the Active Job retry" do
    EmailConnection::Gmail::Synchronizer.stubs(:call)
      .raises(EmailConnection::Errors::TemporaryProviderError, "temporarily unavailable")

    assert_enqueued_with(
      job: EmailConnections::SyncInboundJob,
      args: [ @connection.id, @provider_account_id, @credential_generation ]
    ) do
      EmailConnections::SyncInboundJob.perform_now(
        @connection.id,
        @provider_account_id,
        @credential_generation
      )
    end

    assert @connection.reload.inbound_sync_job_id
    assert @connection.inbound_sync_enqueued_at
  end

  test "a retry enqueue failure releases the sync reservation" do
    EmailConnection::Gmail::Synchronizer.stubs(:call)
      .raises(EmailConnection::Errors::TemporaryProviderError, "temporarily unavailable")
    ActiveJob::Base.queue_adapter.stubs(:enqueue_at).raises(RuntimeError, "queue unavailable")

    assert_raises RuntimeError do
      EmailConnections::SyncInboundJob.perform_now(
        @connection.id,
        @provider_account_id,
        @credential_generation
      )
    end

    assert_nil @connection.reload.inbound_sync_job_id
    assert_nil @connection.inbound_sync_enqueued_at
  end

  test "an obsolete worker cannot clear a newer generation reservation" do
    old_job = EmailConnections::SyncInboundJob.new(
      @connection.id,
      @provider_account_id,
      @credential_generation
    )
    assert @connection.reserve_inbound_sync_enqueue!(
      job_id: old_job.job_id,
      provider_account_id: @provider_account_id,
      credential_generation: @credential_generation
    )

    new_generation = @credential_generation + 1
    @connection.update_columns(
      credential_generation: new_generation,
      inbound_sync_job_id: nil,
      inbound_sync_enqueued_at: nil
    )
    new_job = EmailConnections::SyncInboundJob.new(
      @connection.id,
      @provider_account_id,
      new_generation
    )
    assert @connection.reserve_inbound_sync_enqueue!(
      job_id: new_job.job_id,
      provider_account_id: @provider_account_id,
      credential_generation: new_generation
    )
    EmailConnection::Gmail::Synchronizer.expects(:call).never

    old_job.perform_now

    assert_equal new_job.job_id, @connection.reload.inbound_sync_job_id
  end
end
