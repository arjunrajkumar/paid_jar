class InvoiceMessage < ApplicationRecord
  OUTBOUND_CONTACT_COOLDOWN = 48.hours

  DIRECTIONS = {
    inbound: "inbound",
    outbound: "outbound"
  }.freeze
  KINDS = {
    customer_reply: "customer_reply",
    scheduled_reminder: "scheduled_reminder",
    due_date_answer: "due_date_answer",
    payment_status_answer: "payment_status_answer",
    invoice_resend: "invoice_resend",
    promise_follow_up: "promise_follow_up",
    dispute_acknowledgement: "dispute_acknowledgement"
  }.freeze
  STATUSES = {
    pending: "pending",
    sent: "sent",
    failed: "failed",
    received: "received"
  }.freeze

  belongs_to :account, inverse_of: :invoice_messages
  belongs_to :invoice, inverse_of: :invoice_messages
  has_one :invoice_reminder,
    dependent: :restrict_with_exception,
    inverse_of: :invoice_message
  has_one :payment_promise,
    foreign_key: :source_message_id,
    dependent: :restrict_with_exception,
    inverse_of: :source_message
  has_one :payment_promise_follow_up,
    class_name: "PaymentPromise",
    foreign_key: :follow_up_message_id,
    dependent: :restrict_with_exception,
    inverse_of: :follow_up_message

  enum :direction, DIRECTIONS, prefix: true, validate: true
  enum :kind, KINDS, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true

  attribute :to_addresses, default: -> { [] }
  attribute :cc_addresses, default: -> { [] }

  normalizes :from_address, with: ->(address) { address.to_s.strip.downcase.presence }
  normalizes :provider_message_id,
    :provider_thread_id,
    :delivery_job_id,
    with: ->(id) { id.to_s.strip.presence }

  validates :provider_message_id,
    uniqueness: { scope: :account_id },
    allow_nil: true
  validates :sent_at, presence: true, if: :status_sent?
  validates :received_at, presence: true, if: :status_received?
  validate :account_matches_invoice
  validate :status_matches_direction
  validate :timestamps_match_status
  validate :successful_messages_have_no_failure_reason
  validate :address_lists_are_arrays

  scope :successful_outbound, -> { direction_outbound.status_sent }
  scope :sent_after, ->(time) { where(arel_table[:sent_at].gt(time)) }
  scope :stale_pending_deliveries, ->(before:) do
    pending_messages = direction_outbound.status_pending
    attempted = pending_messages.where(delivery_attempted_at: ...before)
    untracked = pending_messages.where(delivery_attempted_at: nil, created_at: ...before)

    attempted.or(untracked)
  end

  def delivery_owned_by?(job_id)
    normalized_job_id = job_id.to_s.strip.presence

    status_pending? && normalized_job_id.present? && delivery_job_id == normalized_job_id
  end

  def refresh_delivery_attempt!(job_id:, mail_message:, attempted_at: Time.current)
    with_owned_pending_delivery(job_id:) do
      update!(
        InvoiceMessages::Content.from_mail(mail_message).attributes.merge(
          delivery_attempted_at: attempted_at
        )
      )
    end
  end

  def mark_delivery_sent!(
    job_id:,
    sent_at: Time.current,
    provider_message_id:,
    provider_thread_id: nil
  )
    with_owned_pending_delivery(job_id:) do
      update!(
        status: :sent,
        sent_at:,
        provider_message_id:,
        provider_thread_id:,
        failure_reason: nil
      )
    end
  end

  def mark_delivery_failed!(job_id:, failure_reason:)
    with_owned_pending_delivery(job_id:) do
      fail_delivery!(failure_reason:)
    end
  end

  def reconcile_stale_delivery!(before:, failure_reason:)
    reconciled = false

    with_lock do
      next unless stale_pending_delivery?(before:)

      fail_delivery!(failure_reason:)
      payment_promise_follow_up&.follow_up_failed!
      reconciled = true
    end

    reconciled
  end

  private
    def with_owned_pending_delivery(job_id:)
      updated = false

      with_lock do
        next unless delivery_owned_by?(job_id)

        yield
        updated = true
      end

      updated
    end

    def stale_pending_delivery?(before:)
      return false unless direction_outbound? && status_pending?

      (delivery_attempted_at || created_at) < before
    end

    def fail_delivery!(failure_reason:)
      update!(
        status: :failed,
        sent_at: nil,
        provider_message_id: nil,
        provider_thread_id: nil,
        failure_reason:
      )
    end

    def account_matches_invoice
      return if account.blank? || invoice.blank? || account == invoice.account

      errors.add(:account, "must match invoice account")
    end

    def status_matches_direction
      return if direction.blank? || status.blank?

      if direction_inbound? && !status_received?
        errors.add(:status, "must be received for inbound messages")
      elsif direction_outbound? && status_received?
        errors.add(:status, "must be received only for inbound messages")
      end
    end

    def timestamps_match_status
      if status_sent?
        errors.add(:received_at, "must be blank for sent messages") if received_at.present?
      elsif status_received?
        errors.add(:sent_at, "must be blank for received messages") if sent_at.present?
      else
        errors.add(:sent_at, "must be blank until the message is sent") if sent_at.present?
        errors.add(:received_at, "must be blank unless the message was received") if received_at.present?
      end
    end

    def successful_messages_have_no_failure_reason
      return unless (status_sent? || status_received?) && failure_reason.present?

      errors.add(:failure_reason, "must be blank for successful messages")
    end

    def address_lists_are_arrays
      errors.add(:to_addresses, "must be an array") unless to_addresses.is_a?(Array)
      errors.add(:cc_addresses, "must be an array") unless cc_addresses.is_a?(Array)
    end
end
