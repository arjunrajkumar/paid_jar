class Account < ApplicationRecord
  PAYER_SEGMENT_HISTORY_OPTIONS = (1..12).to_a.freeze
  PAYER_SEGMENT_PAYS_ON_TIME_RATE_OPTIONS = (50..100).step(5).to_a.freeze
  PAYER_SEGMENT_UNRELIABLE_ON_TIME_RATE_OPTIONS = (0..75).step(5).to_a.freeze
  PAYER_SEGMENT_SLOW_PAYER_DAYS_OPTIONS = [ 1, 3, 5, 7, 10, 14, 21, 30, 45, 60, 90 ].freeze
  PAYER_SEGMENT_RULE_ATTRIBUTES = %i[
    payer_segment_minimum_payment_history
    payer_segment_minimum_unreliable_history
    payer_segment_pays_on_time_rate
    payer_segment_unreliable_on_time_rate
    payer_segment_slow_payer_days
  ].freeze

  has_many :invoice_sources, dependent: :destroy
  has_many :customers, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :receivables, dependent: :destroy
  has_many :users, dependent: :destroy

  before_create :assign_external_account_id

  validates :name, presence: true
  validates :payer_segment_minimum_payment_history,
    :payer_segment_minimum_unreliable_history,
    inclusion: { in: PAYER_SEGMENT_HISTORY_OPTIONS }
  validates :payer_segment_pays_on_time_rate,
    inclusion: { in: PAYER_SEGMENT_PAYS_ON_TIME_RATE_OPTIONS }
  validates :payer_segment_unreliable_on_time_rate,
    inclusion: { in: PAYER_SEGMENT_UNRELIABLE_ON_TIME_RATE_OPTIONS }
  validates :payer_segment_slow_payer_days,
    inclusion: { in: PAYER_SEGMENT_SLOW_PAYER_DAYS_OPTIONS }
  validate :unreliable_history_covers_minimum_history
  validate :unreliable_rate_is_below_pays_on_time_rate

  class << self
    def create_with_owner(account:, owner:)
      transaction do
        create!(**account).tap do |account|
          account.users.create!(role: :system, name: "System")
          account.users.create!(**owner.with_defaults(role: :owner, verified_at: Time.current))
        end
      end
    end
  end

  def slug
    "/#{AccountSlug.encode(external_account_id)}"
  end

  def active?
    true
  end

  private
    def unreliable_history_covers_minimum_history
      return if payer_segment_minimum_payment_history.nil? || payer_segment_minimum_unreliable_history.nil?
      return if payer_segment_minimum_unreliable_history >= payer_segment_minimum_payment_history

      errors.add(:payer_segment_minimum_unreliable_history, "must be at least the minimum payment history")
    end

    def unreliable_rate_is_below_pays_on_time_rate
      return if payer_segment_pays_on_time_rate.nil? || payer_segment_unreliable_on_time_rate.nil?
      return if payer_segment_unreliable_on_time_rate < payer_segment_pays_on_time_rate

      errors.add(:payer_segment_unreliable_on_time_rate, "must be lower than the pays-on-time rate")
    end

    def assign_external_account_id
      self.external_account_id ||= ExternalIdSequence.next
    end
end
