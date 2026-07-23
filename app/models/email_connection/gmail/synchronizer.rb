require "set"

class EmailConnection::Gmail::Synchronizer
  INITIAL_LOOKBACK = 7.days
  RECOVERY_OVERLAP = 1.hour

  def self.call(
    connection,
    mailbox: nil,
    provider_account_id: connection.provider_account_id,
    credential_generation: connection.credential_generation
  )
    mailbox ||= EmailConnection::Gmail::Mailbox.new(
      connection:,
      provider_account_id:,
      credential_generation:
    )
    new(
      connection,
      mailbox:,
      provider_account_id:,
      credential_generation:
    ).call
  end

  def initialize(connection, mailbox:, provider_account_id:, credential_generation:)
    @connection = connection
    @mailbox = mailbox
    @provider_account_id = provider_account_id.to_s.strip
    @credential_generation = credential_generation.to_i
  end

  def call
    connection.assert_gmail_credentials_current!(
      provider_account_id:,
      credential_generation:
    )
    connection.reload
    return unless connection.inbound_ready?

    sync_started_at = Time.current
    starting_cursor = connection.inbound_cursor.to_s
    EmailConnection.where(
      id: connection.id,
      status: EmailConnection.statuses.fetch(:active),
      provider_account_id:,
      credential_generation:
    ).update_all(last_inbound_attempted_at: sync_started_at, updated_at: Time.current)

    terminal_cursor, receipt_ids = if connection.last_inbound_synced_at.nil?
      initial_sync(starting_cursor:, sync_started_at:)
    else
      incremental_sync(starting_cursor:)
    end

    checkpointed = checkpoint!(
      starting_cursor:,
      terminal_cursor:,
      synced_at: Time.current
    )
    unless checkpointed
      retire_replaced_mailbox_receipts(receipt_ids)
      return receipt_ids
    end
    enqueue_receipts(receipt_ids)
    receipt_ids
  rescue EmailConnection::Errors::HistoryExpired
    begin
      terminal_cursor, receipt_ids = recovery_sync(sync_started_at: sync_started_at || Time.current)
      checkpointed = checkpoint!(
        starting_cursor:,
        terminal_cursor:,
        synced_at: Time.current
      )
      unless checkpointed
        retire_replaced_mailbox_receipts(receipt_ids)
        return receipt_ids
      end
      enqueue_receipts(receipt_ids)
      receipt_ids
    rescue StandardError => error
      record_error(error)
      raise
    end
  rescue StandardError => error
    record_error(error)
    raise
  end

  private
    attr_reader :connection, :mailbox, :provider_account_id, :credential_generation

    def initial_sync(starting_cursor:, sync_started_at:)
      receipt_ids = scan_since(sync_started_at - INITIAL_LOOKBACK)
      terminal_cursor, history_receipt_ids = history_since(starting_cursor)
      [ terminal_cursor, (receipt_ids + history_receipt_ids).uniq ]
    end

    def incremental_sync(starting_cursor:)
      history_since(starting_cursor)
    end

    def recovery_sync(sync_started_at:)
      baseline_cursor = mailbox.profile.history_id.to_s
      lookback = connection.last_inbound_synced_at&.-(RECOVERY_OVERLAP) ||
        (sync_started_at - INITIAL_LOOKBACK)
      receipt_ids = scan_since(lookback)
      terminal_cursor, history_receipt_ids = history_since(baseline_cursor)
      [ terminal_cursor, (receipt_ids + history_receipt_ids).uniq ]
    end

    def scan_since(time)
      receipt_ids = []
      mailbox.each_message_since(time:) do |message|
        receipt = persist_receipt(
          provider_message_id: message.id,
          provider_thread_id: message.thread_id
        )
        receipt_ids << receipt.id if receipt
      end
      receipt_ids
    end

    def history_since(cursor)
      terminal_cursor = cursor.to_s
      receipt_ids = []
      seen_message_ids = Set.new

      mailbox.each_history_page(start_history_id: cursor) do |page|
        terminal_cursor = page.history_id.to_s if page.history_id.present?
        Array(page.history).each do |history|
          Array(history.messages_added).each do |addition|
            message = addition.message
            next if message.blank? || !seen_message_ids.add?(message.id.to_s)

            receipt = persist_receipt(
              provider_message_id: message.id,
              provider_thread_id: message.thread_id,
              provider_history_id: history.id
            )
            receipt_ids << receipt.id if receipt
          end
        end
      end

      [ terminal_cursor, receipt_ids ]
    end

    def persist_receipt(provider_message_id:, provider_thread_id: nil, provider_history_id: nil)
      receipt = connection.email_message_receipts.create_or_find_by!(
        provider_account_id:,
        provider_message_id: provider_message_id.to_s
      ) do |receipt|
        receipt.account = connection.account
        receipt.email_connection_generation = credential_generation
        receipt.provider_thread_id = provider_thread_id.to_s.presence
        receipt.provider_history_id = provider_history_id.to_s.presence
        receipt.discovered_at = Time.current
        receipt.metadata = {}
      end
      receipt if receipt.prepare_for_generation!(generation: credential_generation)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
      if error.is_a?(ActiveRecord::RecordInvalid) &&
          !error.record.errors.of_kind?(:provider_message_id, :taken)
        raise
      end

      receipt = connection.email_message_receipts.find_by!(
        provider_account_id:,
        provider_message_id: provider_message_id.to_s
      )
      receipt if receipt.prepare_for_generation!(generation: credential_generation)
    end

    def checkpoint!(starting_cursor:, terminal_cursor:, synced_at:)
      updated = EmailConnection.where(
        id: connection.id,
        status: EmailConnection.statuses.fetch(:active),
        provider_account_id:,
        credential_generation:,
        inbound_cursor: starting_cursor
      ).update_all(
        inbound_cursor: terminal_cursor.to_s,
        last_inbound_synced_at: synced_at,
        last_inbound_error: nil,
        updated_at: Time.current
      )
      connection.reload
      updated == 1
    end

    def enqueue_receipts(receipt_ids)
      EmailMessageReceipt.where(id: receipt_ids, status: :pending).find_each do |receipt|
        EmailMessageReceipts::ProcessJob.enqueue(receipt) if receipt.current_mailbox?
      end
    end

    def retire_replaced_mailbox_receipts(receipt_ids)
      connection.reload
      return if connection.provider_account_id == provider_account_id &&
        connection.credential_generation == credential_generation

      EmailMessageReceipt.where(
        id: receipt_ids,
        provider_account_id:,
        email_connection_generation: credential_generation
      ).find_each do |receipt|
        receipt.retire_unprocessed!(
          reason: connection.provider_account_id == provider_account_id ?
            :credentials_replaced :
            :mailbox_replaced,
          expected_provider_account_id: provider_account_id,
          expected_generation: credential_generation
        )
      end
    end

    def record_error(error)
      return if provider_account_id.blank?

      EmailConnection.where(
        id: connection.id,
        status: EmailConnection.statuses.fetch(:active),
        provider_account_id:,
        credential_generation:
      ).update_all(
        last_inbound_error: error.class.name,
        updated_at: Time.current
      )
    end
end
