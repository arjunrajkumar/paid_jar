class InvoiceMessage < ApplicationRecord
  FOLLOW_UP_COOLDOWN = 48.hours

  DIRECTIONS = {
    inbound: "inbound",
    outbound: "outbound"
  }.freeze
  KINDS = {
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

  enum :direction, DIRECTIONS, prefix: true, validate: true
  enum :kind, KINDS, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true

  attribute :to_addresses, default: -> { [] }
  attribute :cc_addresses, default: -> { [] }

  normalizes :from_address, with: ->(address) { address.to_s.strip.downcase.presence }
  normalizes :provider_message_id, :provider_thread_id, with: ->(id) { id.to_s.strip.presence }

  validates :provider_message_id,
    uniqueness: { scope: :account_id },
    allow_nil: true
  validates :sent_at, presence: true, if: :status_sent?
  validates :received_at, presence: true, if: :status_received?
  validate :account_matches_invoice
  validate :status_matches_direction
  validate :address_lists_are_arrays

  scope :successful_outbound, -> { direction_outbound.status_sent }
  scope :sent_after, ->(time) { where(arel_table[:sent_at].gt(time)) }

  private
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

    def address_lists_are_arrays
      errors.add(:to_addresses, "must be an array") unless to_addresses.is_a?(Array)
      errors.add(:cc_addresses, "must be an array") unless cc_addresses.is_a?(Array)
    end
end
