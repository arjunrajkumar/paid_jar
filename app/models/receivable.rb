class Receivable < ApplicationRecord
  STATUSES = %w[ none outstanding uncollectible open paid ].index_by(&:itself).freeze
  PAYER_SEGMENTS = %w[ new pays_on_time sometimes_late slow_payer unreliable_payer ].index_by(&:itself).freeze

  PAYMENT_HISTORY_LIMIT = 12
  MINIMUM_PAYMENT_HISTORY = 3
  MINIMUM_UNRELIABLE_HISTORY = 5
  PAYS_ON_TIME_RATE = 80
  UNRELIABLE_ON_TIME_RATE = 50
  SLOW_PAYER_DAYS = 7

  belongs_to :account, inverse_of: :receivables
  belongs_to :customer, inverse_of: :receivable

  attribute :outstanding_totals, default: -> { {} }
  attribute :uncollectible_totals, default: -> { {} }

  enum :status, STATUSES, prefix: true, validate: true
  enum :payer_segment, PAYER_SEGMENTS, prefix: true, validate: true

  validates :customer_id, uniqueness: true
  validate :account_matches_customer

  scope :active, -> { where.not(status: :none) }

  class << self
    def refresh_for!(customer)
      customer.with_lock do
        invoices = customer.invoices.issued.recent.to_a
        receivable = customer.receivable || customer.build_receivable

        receivable.update!(
          account: customer.account,
          **summary_attributes(invoices),
          payer_segment: payer_segment_for(invoices),
          calculated_at: Time.current
        )
        receivable
      end
    end

    private
      def summary_attributes(invoices)
        open_invoices = invoices.select(&:open?)
        outstanding_invoices = open_invoices.select(&:outstanding?)
        uncollectible_invoices = invoices.select(&:uncollectible?)

        {
          status: status_for(invoices, open_invoices, outstanding_invoices, uncollectible_invoices),
          due_on: outstanding_invoices.filter_map(&:due_on).min,
          outstanding_totals: amount_due_totals(outstanding_invoices),
          uncollectible_totals: amount_due_totals(uncollectible_invoices),
          open_invoice_count: open_invoices.size,
          outstanding_invoice_count: outstanding_invoices.size,
          uncollectible_invoice_count: uncollectible_invoices.size
        }
      end

      def status_for(invoices, open_invoices, outstanding_invoices, uncollectible_invoices)
        return :outstanding if outstanding_invoices.any?
        return :uncollectible if uncollectible_invoices.any?
        return :open if open_invoices.any?
        return :paid if invoices.any?

        :none
      end

      def amount_due_totals(invoices)
        totals = invoices.each_with_object(Hash.new(0.to_d)) do |invoice, result|
          result[invoice.currency.presence || "Unspecified"] += invoice.amount_due.to_d
        end

        totals.transform_values { |amount| format("%.2f", amount) }
      end

      def payer_segment_for(invoices)
        outcomes = invoices
          .select { |invoice| invoice.uncollectible? || eligible_payment?(invoice) }
          .first(PAYMENT_HISTORY_LIMIT)

        return :unreliable_payer if outcomes.any?(&:uncollectible?)

        payments = outcomes.select(&:paid?)
        return :new if payments.size < MINIMUM_PAYMENT_HISTORY

        delays = payment_delays(payments)
        return :unreliable_payer if unreliable_payment_pattern?(payments, delays)
        return :pays_on_time if on_time_rate(payments) >= PAYS_ON_TIME_RATE
        return :slow_payer if typical_payment_delay(delays).to_i > SLOW_PAYER_DAYS

        :sometimes_late
      end

      def eligible_payment?(invoice)
        invoice.paid? && invoice.due_on.present? && invoice.paid_on.present?
      end

      def unreliable_payment_pattern?(payments, delays)
        payments.size >= MINIMUM_UNRELIABLE_HISTORY &&
          on_time_rate(payments) < UNRELIABLE_ON_TIME_RATE &&
          typical_payment_delay(delays).to_i > SLOW_PAYER_DAYS &&
          inconsistent_payment_timing?(delays)
      end

      def on_time_rate(payments)
        on_time_count = payments.count { |invoice| invoice.paid_on <= invoice.due_on }
        ((on_time_count.to_f / payments.size) * 100).round
      end

      def payment_delays(payments)
        payments.map { |invoice| (invoice.paid_on - invoice.due_on).to_i }
      end

      def typical_payment_delay(delays)
        median(forecast_payment_delays(delays))
      end

      def inconsistent_payment_timing?(delays)
        forecast_delays = forecast_payment_delays(delays)
        forecast_delays.size < 3 || forecast_delays.max - forecast_delays.min > 14
      end

      def forecast_payment_delays(delays)
        return delays if delays.size < MINIMUM_PAYMENT_HISTORY

        typical_delay = median(delays)
        deviations = delays.map { |delay| (delay - typical_delay).abs }
        threshold = [ median(deviations) * 3, 30 ].max

        delays.reject { |delay| (delay - typical_delay).abs > threshold }
      end

      def median(values)
        return if values.empty?

        sorted_values = values.sort
        midpoint = sorted_values.length / 2
        return sorted_values.fetch(midpoint) if sorted_values.length.odd?

        ((sorted_values.fetch(midpoint - 1) + sorted_values.fetch(midpoint)) / 2.0).round
      end
  end

  def overdue?(as_of: Date.current)
    status_outstanding? && due_on.present? && due_on < as_of
  end

  def display_status(as_of: Date.current)
    overdue?(as_of:) ? :overdue : status.to_sym
  end

  private
    def account_matches_customer
      return if account.blank? || customer.blank? || account_id == customer.account_id

      errors.add(:account, "must match customer account")
    end
end
