class EmailConnections::SyncInboundJob < ApplicationJob
  queue_as :default

  limits_concurrency(
    to: 1,
    key: ->(email_connection_id, *) { email_connection_id.to_s },
    duration: 30.minutes,
    group: "GmailInboundSync",
    on_conflict: :block
  )

  retry_on EmailConnection::Errors::TemporaryProviderError,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.release_inbound_sync_reservation
      raise error
    end

  around_enqueue do |job, enqueue|
    enqueue.call
  ensure
    job.release_inbound_sync_reservation unless job.successfully_enqueued?
  end

  def self.enqueue(connection)
    connection.reload
    provider_account_id = connection.provider_account_id
    credential_generation = connection.credential_generation
    job = new(connection.id, provider_account_id, credential_generation)
    return false unless connection.reserve_inbound_sync_enqueue!(
      job_id: job.job_id,
      provider_account_id:,
      credential_generation:
    )

    enqueued = job.enqueue
    return enqueued if enqueued

    raise(job.enqueue_error || ActiveJob::EnqueueError.new("Could not enqueue Gmail inbound sync"))
  rescue StandardError
    connection.release_inbound_sync_enqueue!(job_id: job.job_id) if connection && job
    raise
  end

  def perform(email_connection_id, provider_account_id, credential_generation)
    connection = EmailConnection.find_by(id: email_connection_id)
    return unless connection
    unless connection.start_inbound_sync!(
      job_id:,
      provider_account_id:,
      credential_generation:
    )
      connection.release_inbound_sync_enqueue!(job_id:)
      return
    end

    mailbox = EmailConnection::Gmail::Mailbox.new(
      connection:,
      provider_account_id:,
      credential_generation:
    )
    EmailConnection::Gmail::Synchronizer.call(
      connection,
      mailbox:,
      provider_account_id:,
      credential_generation:
    )
    connection.release_inbound_sync_enqueue!(job_id:)
  rescue EmailConnection::Errors::CredentialChanged
    connection&.release_inbound_sync_enqueue!(job_id:)
    nil
  rescue EmailConnection::Errors::TemporaryProviderError
    raise
  rescue StandardError
    connection&.release_inbound_sync_enqueue!(job_id:)
    raise
  end

  def release_inbound_sync_reservation
    connection = EmailConnection.find_by(id: arguments.first)
    connection&.release_inbound_sync_enqueue!(job_id:)
  end
end
