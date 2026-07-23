class EmailConnection < ApplicationRecord
  include Gmailable

  INBOUND_SYNC_RESERVATION_STALE_AFTER = 1.hour

  belongs_to :account, inverse_of: :email_connection
  has_many :email_message_receipts,
    dependent: :destroy,
    inverse_of: :email_connection
  has_many :conversation_messages,
    dependent: :nullify,
    inverse_of: :email_connection

  attribute :scopes, default: -> { [] }

  encrypts :access_token, :refresh_token

  enum :provider, { gmail: "gmail" }, validate: true
  enum :status, {
    pending: "pending",
    active: "active",
    disconnected: "disconnected",
    errored: "errored"
  }, validate: true

  validates :account_id, uniqueness: true
  validates :connected_email,
    presence: true,
    format: { with: URI::MailTo::EMAIL_REGEXP },
    length: { maximum: 254 }
  validates :access_token, :refresh_token, presence: true, if: :active?
  validates :credential_generation,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  normalizes :connected_email, with: ->(value) { value.strip.downcase.presence }
  normalizes :inbound_sync_job_id, with: ->(value) { value.to_s.strip.presence }

  def disconnect!
    transaction do
      lock!
      account.update!(automatic_invoice_reminders_enabled: false)
      update!(
        status: :disconnected,
        access_token: nil,
        refresh_token: nil,
        token_expires_at: nil,
        provider_account_id: nil,
        inbound_cursor: nil,
        inbound_enabled_at: nil,
        last_inbound_attempted_at: nil,
        last_inbound_synced_at: nil,
        last_inbound_error: nil,
        last_error: nil,
        credential_generation: credential_generation + 1,
        inbound_sync_job_id: nil,
        inbound_sync_enqueued_at: nil
      )
      email_message_receipts
        .where(status: %i[pending processing failed])
        .find_each { |receipt| receipt.retire_unprocessed!(reason: :mailbox_disconnected) }
    end
  end

  def mark_errored!(
    error,
    provider_account_id:,
    credential_generation:,
    access_token: nil,
    refresh_token: nil
  )
    marked = false
    with_lock do
      next unless gmail_credentials_match?(
        provider_account_id:,
        credential_generation:
      )
      next if access_token.present? && self.access_token != access_token
      next if refresh_token.present? && self.refresh_token != refresh_token

      update!(
        status: :errored,
        last_error: "gmail_authentication_failed",
        last_inbound_error: error.class.name,
        inbound_sync_job_id: nil,
        inbound_sync_enqueued_at: nil
      )
      marked = true
    end
    marked
  end

  def sender_matches?(address)
    connected_email.present? && address.present? && connected_email.casecmp?(address)
  end

  def reserve_inbound_sync_enqueue!(
    job_id:,
    provider_account_id:,
    credential_generation:,
    at: Time.current
  )
    reserved = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless gmail_credentials_match?(
        provider_account_id:,
        credential_generation:
      )
      next unless inbound_ready?
      next if inbound_sync_enqueue_reserved?(at:)

      update!(
        inbound_sync_job_id: normalized_job_id,
        inbound_sync_enqueued_at: at
      )
      reserved = true
    end
    reserved
  end

  def start_inbound_sync!(
    job_id:,
    provider_account_id:,
    credential_generation:,
    at: Time.current
  )
    started = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless gmail_credentials_match?(
        provider_account_id:,
        credential_generation:
      )
      next unless inbound_ready?
      next if inbound_sync_job_id.present? && inbound_sync_job_id != normalized_job_id

      update!(
        inbound_sync_job_id: normalized_job_id,
        inbound_sync_enqueued_at: at
      )
      started = true
    end
    started
  end

  def release_inbound_sync_enqueue!(job_id:)
    released = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless inbound_sync_job_id == normalized_job_id

      update!(
        inbound_sync_job_id: nil,
        inbound_sync_enqueued_at: nil
      )
      released = true
    end
    released
  end

  private
    def gmail_credentials_match?(provider_account_id:, credential_generation:)
      active_gmail_connection? &&
        self.provider_account_id == provider_account_id.to_s.strip &&
        self.credential_generation == credential_generation.to_i
    end

    def inbound_sync_enqueue_reserved?(at:)
      inbound_sync_job_id.present? &&
        inbound_sync_enqueued_at.present? &&
        inbound_sync_enqueued_at >= INBOUND_SYNC_RESERVATION_STALE_AFTER.ago(at)
    end
end
