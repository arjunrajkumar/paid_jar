require "test_helper"

class EmailMessageReceiptTest < ActiveSupport::TestCase
  setup do
    @connection = email_connections(:paid_jar_gmail)
    @receipt = @connection.email_message_receipts.create!(
      account: @connection.account,
      provider_message_id: "gmail-receipt-1",
      discovered_at: Time.current
    )
  end

  test "claims and completes only for the owning job" do
    assert @receipt.claim!(job_id: "job-1")
    assert_equal 1, @receipt.attempts
    assert @receipt.processing_owned_by?("job-1")
    assert_not @receipt.complete!(
      job_id: "job-2",
      conversation_message: nil,
      direction: :inbound
    )
    assert_predicate @receipt.reload, :status_processing?

    assert @receipt.ignore!(job_id: "job-1", reason: :unrelated, direction: :inbound)
    assert_predicate @receipt.reload, :status_ignored?
    assert_equal "unrelated", @receipt.metadata.fetch("reason")
    assert_not @receipt.claim!(job_id: "job-3")
  end

  test "failed receipts become independently retryable when due" do
    error = EmailConnection::Errors::TemporaryProviderError.new("private provider text")
    @receipt.claim!(job_id: "job-1")
    assert @receipt.fail!(job_id: "job-1", error:, retry_at: 1.minute.ago)

    assert_predicate @receipt.reload, :status_failed?
    assert_equal error.class.name, @receipt.last_error
    assert @receipt.claim!(job_id: "job-2")
    assert_equal 2, @receipt.reload.attempts
  end

  test "reserves one queued processor and only its owner can claim or release it" do
    assert @receipt.reserve_processing_enqueue!(job_id: "queued-job")
    assert_not @receipt.reserve_processing_enqueue!(job_id: "duplicate-job")
    assert_not @receipt.claim!(job_id: "duplicate-job")
    assert_not @receipt.release_processing_enqueue!(job_id: "duplicate-job")

    assert @receipt.claim!(job_id: "queued-job")
    assert_predicate @receipt.reload, :status_processing?
    assert_nil @receipt.processing_enqueued_job_id
    assert_nil @receipt.processing_enqueued_at
  end

  test "a stale queued processor reservation can be replaced safely" do
    assert @receipt.reserve_processing_enqueue!(
      job_id: "lost-job",
      at: EmailMessageReceipt::ENQUEUE_RESERVATION_STALE_AFTER.ago - 1.minute
    )
    assert @receipt.reserve_processing_enqueue!(job_id: "replacement-job")

    assert_equal "replacement-job", @receipt.reload.processing_enqueued_job_id
    assert_not @receipt.release_processing_enqueue!(job_id: "lost-job")
    assert @receipt.release_processing_enqueue!(job_id: "replacement-job")
  end

  test "recovers stale processing without changing terminal receipts" do
    @receipt.claim!(job_id: "job-1", at: 1.hour.ago)
    assert @receipt.recover_stale_processing!(before: 30.minutes.ago)
    assert_predicate @receipt.reload, :status_pending?

    @receipt.claim!(job_id: "job-2")
    @receipt.ignore!(job_id: "job-2", reason: :draft)
    assert_not @receipt.recover_stale_processing!(before: 30.minutes.from_now)
    assert_predicate @receipt.reload, :status_ignored?
  end

  test "enforces account and connection isolation" do
    other_account = Account.create!(name: "Other receipt account")
    isolated = EmailMessageReceipt.new(
      account: other_account,
      email_connection: @connection,
      provider_message_id: "gmail-receipt-isolated",
      discovered_at: Time.current
    )

    assert_not isolated.valid?
    assert_includes isolated.errors[:account], "must match email connection account"
  end

  test "deduplicates provider IDs case-sensitively per connection" do
    duplicate = @receipt.dup
    case_variant = @receipt.dup
    case_variant.provider_message_id = @receipt.provider_message_id.upcase

    assert_not duplicate.valid?
    assert case_variant.save
  end

  test "captures an immutable mailbox identity and scopes provider deduplication to it" do
    assert_equal @connection.provider_account_id, @receipt.provider_account_id
    assert_equal @connection.credential_generation, @receipt.email_connection_generation

    @connection.update_column(:provider_account_id, "replacement-google-account")
    replacement_receipt = @connection.email_message_receipts.create!(
      account: @connection.account,
      provider_message_id: @receipt.provider_message_id,
      discovered_at: Time.current
    )

    assert_equal "replacement-google-account", replacement_receipt.provider_account_id
    assert_not @receipt.reload.current_mailbox?
    assert_not @receipt.claim!(job_id: "stale-job")

    @receipt.provider_account_id = "mutated-google-account"
    assert_not @receipt.valid?
    assert_includes @receipt.errors[:provider_account_id], "cannot be changed"
  end

  test "credential generations isolate queued work even when Google identity is unchanged" do
    @connection.increment!(:credential_generation)

    assert_not @receipt.reload.current_mailbox?
    assert @receipt.retire_if_mailbox_replaced!
    assert_equal "credentials_replaced", @receipt.reload.metadata.fetch("reason")

    assert @receipt.prepare_for_generation!(generation: @connection.credential_generation)
    assert_predicate @receipt.reload, :status_pending?
    assert @receipt.current_mailbox?
    assert_equal @connection.credential_generation, @receipt.email_connection_generation
  end

  test "switching back to a prior Gmail identity resurrects its unprocessed message" do
    @connection.connect_gmail!(
      email: "replacement@example.com",
      name: "Replacement",
      provider_account_id: "replacement-google-account",
      history_id: "200",
      access_token: "replacement-access",
      refresh_token: "replacement-refresh",
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )
    assert_predicate @receipt.reload, :status_ignored?
    assert_equal "mailbox_replaced", @receipt.metadata.fetch("reason")

    @connection.connect_gmail!(
      email: "billing@paymentreminder.example",
      name: "Billing",
      provider_account_id: @receipt.provider_account_id,
      history_id: "300",
      access_token: "restored-access",
      refresh_token: "restored-refresh",
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )

    assert @receipt.prepare_for_generation!(generation: @connection.credential_generation)
    assert_predicate @receipt.reload, :status_pending?
    assert @receipt.current_mailbox?
    assert_equal @connection.credential_generation, @receipt.email_connection_generation
    assert_empty @receipt.metadata
  end

  test "processor concurrency keys serialize one Gmail thread but not unrelated threads" do
    same_thread = @connection.email_message_receipts.create!(
      account: @connection.account,
      provider_message_id: "gmail-receipt-same-thread",
      provider_thread_id: "shared-thread",
      discovered_at: Time.current
    )
    other_thread = @connection.email_message_receipts.create!(
      account: @connection.account,
      provider_message_id: "gmail-receipt-other-thread",
      provider_thread_id: "other-thread",
      discovered_at: Time.current
    )
    @receipt.update!(provider_thread_id: "shared-thread")

    assert_equal(
      EmailMessageReceipt.processing_concurrency_key(@receipt.id),
      EmailMessageReceipt.processing_concurrency_key(same_thread.id)
    )
    assert_not_equal(
      EmailMessageReceipt.processing_concurrency_key(@receipt.id),
      EmailMessageReceipt.processing_concurrency_key(other_thread.id)
    )
  end

  test "retires stale mailbox work without exposing provider content" do
    @connection.update_column(:provider_account_id, "replacement-google-account")

    assert @receipt.retire_if_mailbox_replaced!
    assert_predicate @receipt.reload, :status_ignored?
    assert_equal "mailbox_replaced", @receipt.metadata.fetch("reason")
    assert_nil @receipt.processing_job_id
    assert_nil @receipt.next_retry_at
  end

  test "only terminal failures can be explicitly retried" do
    @receipt.claim!(job_id: "job-1")
    @receipt.fail!(
      job_id: "job-1",
      error: EmailConnection::Errors::PermanentProviderError.new("private response"),
      retry_at: nil
    )

    assert @receipt.retry!
    assert_predicate @receipt.reload, :status_pending?
    assert_equal 0, @receipt.attempts
    assert_nil @receipt.last_error

    @receipt.claim!(job_id: "job-2")
    @receipt.fail!(
      job_id: "job-2",
      error: EmailConnection::Errors::TemporaryProviderError.new("private response"),
      retry_at: 5.minutes.from_now
    )
    assert_not @receipt.retry!
  end
end
