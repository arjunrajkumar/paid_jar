class ConversationMessage < ApplicationRecord
  OUTBOUND_CONTACT_COOLDOWN = 48.hours

  DIRECTIONS = {
    inbound: "inbound",
    outbound: "outbound"
  }.freeze
  KINDS = {
    customer_email: "customer_email",
    manual_email: "manual_email",
    customer_reply: "customer_reply",
    scheduled_reminder: "scheduled_reminder",
    manual_reminder: "manual_reminder",
    due_date_answer: "due_date_answer",
    payment_status_answer: "payment_status_answer",
    invoice_resend: "invoice_resend",
    promise_follow_up: "promise_follow_up",
    dispute_acknowledgement: "dispute_acknowledgement"
  }.freeze
  MATCHING_STATUSES = {
    matched: "matched",
    unmatched: "unmatched",
    ambiguous: "ambiguous"
  }.freeze
  MATCHING_METHODS = {
    gmail_thread: "gmail_thread",
    rfc_headers: "rfc_headers",
    invoice_reference: "invoice_reference",
    customer_only: "customer_only",
    none: "none"
  }.freeze
  STATUSES = {
    pending: "pending",
    sent: "sent",
    failed: "failed",
    received: "received"
  }.freeze

  belongs_to :account, inverse_of: :conversation_messages
  belongs_to :conversation, inverse_of: :conversation_messages
  belongs_to :invoice, optional: true, inverse_of: :conversation_messages
  belongs_to :email_connection, optional: true, inverse_of: :conversation_messages
  has_one :email_message_receipt,
    dependent: :nullify,
    inverse_of: :conversation_message
  has_one :invoice_reminder,
    dependent: :restrict_with_exception,
    inverse_of: :conversation_message
  has_one :payment_promise,
    foreign_key: :source_message_id,
    dependent: :restrict_with_exception,
    inverse_of: :source_message
  has_one :payment_promise_follow_up,
    class_name: "PaymentPromise",
    foreign_key: :follow_up_message_id,
    dependent: :restrict_with_exception,
    inverse_of: :follow_up_message
  has_many :conversation_events,
    dependent: :nullify,
    inverse_of: :conversation_message

  enum :direction, DIRECTIONS, prefix: true, validate: true
  enum :kind, KINDS, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true
  enum :matching_status, MATCHING_STATUSES, prefix: true, validate: true
  enum :matching_method, MATCHING_METHODS, prefix: true, validate: true

  attribute :to_addresses, default: -> { [] }
  attribute :cc_addresses, default: -> { [] }
  attribute :bcc_addresses, default: -> { [] }
  attribute :reply_to_addresses, default: -> { [] }
  attribute :in_reply_to_message_ids, default: -> { [] }
  attribute :reference_message_ids, default: -> { [] }
  attribute :provider_metadata, default: -> { {} }
  attribute :review_reasons, default: -> { [] }

  before_validation :assign_outbound_internet_message_id, on: :create
  before_validation :set_internet_message_id_digest
  after_create :touch_conversation

  normalizes :from_address, with: ->(address) { address.to_s.strip.downcase.presence }
  normalizes :provider_account_id,
    :provider_message_id,
    :provider_thread_id,
    :delivery_job_id,
    with: ->(id) { id.to_s.strip.presence }

  validates :provider_message_id,
    uniqueness: { scope: %i[account_id provider_account_id] },
    allow_nil: true
  validates :sent_at, presence: true, if: :status_sent?
  validates :received_at, presence: true, if: :status_received?
  validate :account_matches_invoice
  validate :account_matches_conversation
  validate :account_matches_email_connection
  validate :invoice_matches_conversation
  validate :invoice_required_for_collection_message
  validate :status_matches_direction
  validate :timestamps_match_status
  validate :successful_messages_have_no_failure_reason
  validate :collection_fields_have_expected_types
  validate :gmail_import_has_email_connection
  validate :email_connection_snapshot_is_complete
  validate :provider_account_matches_email_connection, on: :create
  validate :provider_account_is_immutable, on: :update
  validate :email_connection_generation_is_immutable, on: :update

  scope :successful_outbound, -> { direction_outbound.status_sent }
  scope :awaiting_review, -> do
    where.not(email_connection_id: nil).where(review_required: true, reviewed_at: nil)
  end
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
      apply_internet_message_id!(mail_message)
      update!(
        ConversationMessages::Content.from_mail(mail_message).attributes.merge(
          delivery_attempted_at: attempted_at
        )
      )
    end
  end

  def apply_internet_message_id!(mail_message)
    mail_message.message_id = internet_message_id if internet_message_id.present?
    mail_message
  end

  def provider_account_matches?(connection)
    connection.present? &&
      email_connection_id == connection.id &&
      provider_account_id.present? &&
      provider_account_id == connection.provider_account_id &&
      email_connection_generation == connection.credential_generation
  end

  def bind_delivery_mailbox!(connection:, job_id:)
    return true if provider_account_matches?(connection)

    bound = false
    with_lock do
      next unless delivery_owned_by?(job_id)
      next if email_connection_id.present? ||
        provider_account_id.present? ||
        email_connection_generation.present?

      update!(
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id
      )
      bound = true
    end
    bound
  end

  def release_delivery_mailbox_binding!(
    connection:,
    job_id:,
    provider_account_id:,
    credential_generation:
  )
    released = false
    with_lock do
      next unless delivery_owned_by?(job_id)
      next unless provider_message_id.nil?
      next unless email_connection_id == connection.id
      next unless self.provider_account_id == provider_account_id.to_s.strip
      next unless email_connection_generation == credential_generation.to_i

      with_delivery_mailbox_binding_change do
        update!(
          email_connection: nil,
          email_connection_generation: nil,
          provider_account_id: nil
        )
      end
      released = true
    end
    released
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

    def account_matches_conversation
      return if account.blank? || conversation.blank? || account == conversation.account

      errors.add(:account, "must match conversation account")
    end

    def account_matches_email_connection
      return if account.blank? || email_connection.blank? || account == email_connection.account

      errors.add(:email_connection, "must belong to the message account")
    end

    def invoice_matches_conversation
      return if conversation.blank?

      if conversation.invoice.present?
        return if invoice == conversation.invoice

        errors.add(:invoice, "must match conversation invoice")
      elsif invoice.present?
        errors.add(:invoice, "must be blank for an unmatched conversation")
      end
    end

    def invoice_required_for_collection_message
      return if invoice.present?
      return if unmatched_customer_email? || unmatched_manual_email?

      errors.add(:invoice, "is required unless this is a received customer email in an unmatched conversation")
    end

    def unmatched_manual_email?
      conversation&.invoice.blank? &&
        direction_outbound? &&
        status_sent? &&
        kind_manual_email? &&
        email_connection.present?
    end

    def unmatched_customer_email?
      conversation&.invoice.blank? &&
        direction_inbound? &&
        status_received? &&
        kind_customer_email?
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

    def collection_fields_have_expected_types
      %i[
        to_addresses
        cc_addresses
        bcc_addresses
        reply_to_addresses
        in_reply_to_message_ids
        reference_message_ids
        review_reasons
      ].each do |attribute_name|
        errors.add(attribute_name, "must be an array") unless public_send(attribute_name).is_a?(Array)
      end
      errors.add(:provider_metadata, "must be an object") unless provider_metadata.is_a?(Hash)
    end

    def gmail_import_has_email_connection
      return unless kind_customer_email? || kind_manual_email?
      return unless provider_message_id.present?

      errors.add(:email_connection, "is required for Gmail-imported email") if email_connection.blank?
      errors.add(:provider_account_id, "is required for Gmail-imported email") if provider_account_id.blank?
      if email_connection_generation.nil?
        errors.add(:email_connection_generation, "is required for Gmail-imported email")
      end
    end

    def email_connection_snapshot_is_complete
      return if email_connection.blank?

      errors.add(:provider_account_id, "is required with an email connection") if provider_account_id.blank?
      if email_connection_generation.nil?
        errors.add(:email_connection_generation, "is required with an email connection")
      end
    end

    def provider_account_matches_email_connection
      return if email_connection.blank?

      if provider_account_id.present? &&
          provider_account_id != email_connection.provider_account_id
        errors.add(:provider_account_id, "must match the email connection identity")
      end

      if email_connection_generation.present? &&
          email_connection_generation != email_connection.credential_generation
        errors.add(
          :email_connection_generation,
          "must match the email connection credential generation"
        )
      end
    end

    def provider_account_is_immutable
      return unless will_save_change_to_provider_account_id?
      return if @delivery_mailbox_binding_change_allowed
      return if initial_pending_provider_account_binding?

      errors.add(:provider_account_id, "cannot be changed")
    end

    def email_connection_generation_is_immutable
      return unless will_save_change_to_email_connection_generation?
      return if @delivery_mailbox_binding_change_allowed
      return if initial_pending_email_connection_generation_binding?

      errors.add(:email_connection_generation, "cannot be changed")
    end

    def initial_pending_provider_account_binding?
      provider_account_id_was.nil? &&
        provider_account_id.present? &&
        email_connection.present? &&
        provider_account_id == email_connection.provider_account_id &&
        email_connection_generation == email_connection.credential_generation &&
        app_reserved_pending_delivery? &&
        provider_message_id.nil?
    end

    def initial_pending_email_connection_generation_binding?
      email_connection_generation_was.nil? &&
        email_connection_generation.present? &&
        email_connection.present? &&
        provider_account_id == email_connection.provider_account_id &&
        email_connection_generation == email_connection.credential_generation &&
        app_reserved_pending_delivery? &&
        provider_message_id.nil?
    end

    def with_delivery_mailbox_binding_change
      @delivery_mailbox_binding_change_allowed = true
      yield
    ensure
      @delivery_mailbox_binding_change_allowed = false
    end

    def assign_outbound_internet_message_id
      return unless app_reserved_pending_delivery?

      self.internet_message_id ||= "<#{SecureRandom.uuid}@paymentreminder.local>"
    end

    def app_reserved_pending_delivery?
      direction_outbound? && status_pending? && delivery_job_id.present?
    end

    def set_internet_message_id_digest
      self.internet_message_id_digest = if internet_message_id.present?
        Digest::SHA256.hexdigest(internet_message_id)
      end
    end

    def touch_conversation
      conversation.touch
    end
end
