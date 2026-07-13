require "base64"

class Customers::Profile
  attr_reader :as_of, :identity, :invoices

  class << self
    def identity_for(invoice)
      customer_identity = if invoice.contact_external_id.present?
        [ "contact", invoice.contact_external_id ]
      else
        [ "name", invoice.contact_name.to_s.squish.downcase ]
      end

      [ invoice.invoice_source_id, *customer_identity ]
    end

    def to_param_for(invoice)
      encode_identity(identity_for(invoice))
    end

    def encode_identity(identity)
      Base64.urlsafe_encode64(identity.to_json, padding: false)
    end
  end

  def initialize(invoices, identity:, as_of: Date.current)
    @invoices = invoices.sort_by { |invoice| invoice.issued_on || Date.new(1, 1, 1) }.reverse
    @identity = identity
    @as_of = as_of
    @dashboard = Receivables::Dashboard.new(@invoices, as_of: as_of)
    @value_segment = "Standard value"
  end

  def to_param
    self.class.encode_identity(identity)
  end

  def name
    invoices.filter_map { |invoice| invoice.contact_name.presence }.first || "Unknown customer"
  end

  def email
    invoices.filter_map do |invoice|
      invoice.provider_data["customer_email"].presence ||
        invoice.raw_data.dig("Contact", "EmailAddress").presence
    end.first
  end

  def invoice_source
    invoices.first.invoice_source
  end

  def invoice_count
    invoices.size
  end

  def outstanding_invoices
    @dashboard.outstanding_invoices
  end

  def overdue_invoices
    @dashboard.overdue_invoices
  end

  def current_invoices
    @dashboard.current_invoices
  end

  def paid_invoices
    @dashboard.paid_invoices
  end

  def outstanding_totals
    @dashboard.outstanding_totals
  end

  def overdue_totals
    totals_for(overdue_invoices, &:amount_due)
  end

  def total_billed_totals
    totals_for(invoices, &:total)
  end

  def payment_history_count
    paid_invoices_with_dates.size
  end

  def on_time_rate
    return if payment_history_count.zero?

    ((paid_invoices_with_dates.count { |invoice| invoice.paid_on <= invoice.due_on }.to_f / payment_history_count) * 100).round
  end

  def typical_days_from_due
    median(payment_delay_days)
  end

  def forecast_days_from_due
    median(forecast_payment_delays)
  end

  def unusual_payment_dates
    @unusual_payment_dates ||= if payment_history_count < 3
      []
    else
      typical_delay = typical_days_from_due
      deviations = payment_delay_days.map { |delay| (delay - typical_delay).abs }
      threshold = [ median(deviations) * 3, 30 ].max

      paid_invoices_with_dates.select do |invoice|
        (payment_delay_for(invoice) - typical_delay).abs > threshold
      end
    end
  end

  def expected_collection_on(invoice)
    return unless invoice.due_on

    invoice.due_on + (forecast_days_from_due || 0)
  end

  def expected_collection_window(invoice)
    return unless invoice.due_on

    case forecast_payment_delays.size
    when 0
      invoice.due_on..invoice.due_on
    when 1
      expected_on = expected_collection_on(invoice)
      (expected_on - 3.days)..(expected_on + 3.days)
    else
      (invoice.due_on + forecast_payment_delays.min)..(invoice.due_on + forecast_payment_delays.max)
    end
  end

  def next_expected_invoice
    outstanding_invoices.min_by { |invoice| expected_collection_on(invoice) || Date.new(9999, 12, 31) }
  end

  def next_expected_collection_on
    expected_collection_on(next_expected_invoice) if next_expected_invoice
  end

  def forecast_confidence
    return "Due date only" if forecast_payment_delays.empty?

    spread = forecast_payment_delays.max - forecast_payment_delays.min
    return "High" if forecast_payment_delays.size >= 5 && spread <= 7
    return "Medium" if forecast_payment_delays.size >= 3 && spread <= 14

    "Low"
  end

  def comparable_payment_count
    forecast_payment_delays.size
  end

  def forecast_basis
    return "No paid history" if payment_history_count.zero?

    typical_payment_count = payment_history_count - unusual_payment_dates.size
    basis = "Based on #{typical_payment_count} typical #{"payment".pluralize(typical_payment_count)}"
    return basis if unusual_payment_dates.empty?

    "#{basis}; #{unusual_payment_dates.size} unusual #{"date".pluralize(unusual_payment_dates.size)} excluded"
  end

  def payment_history_events(limit: 6)
    paid_invoices_with_dates
      .reject { |invoice| unusual_payment_dates.include?(invoice) }
      .sort_by(&:paid_on)
      .reverse
      .first(limit)
      .map do |invoice|
        delay = payment_delay_for(invoice)

        {
          invoice: invoice,
          delay: delay,
          position: 50 + ((delay.clamp(-30, 30) / 60.0) * 100)
        }
      end
  end

  def last_payment_on
    paid_invoices.filter_map(&:paid_on).max
  end

  def past_expected_date?(invoice)
    expected_on = expected_collection_on(invoice)
    expected_on.present? && expected_on < as_of
  end

  def oldest_overdue_days
    overdue_invoices.filter_map do |invoice|
      (as_of - invoice.due_on).to_i if invoice.due_on
    end.max
  end

  def first_invoice_on
    invoices.filter_map(&:issued_on).min
  end

  def relationship_segment
    return "New customer" if first_invoice_on.blank?
    return "New customer" if invoice_count < 2 || first_invoice_on > as_of - 90.days

    "Established customer"
  end

  def payment_segment
    return "No payment history" if payment_history_count.zero?
    return "Limited payment history" if payment_history_count < 3
    return "Pays on time" if on_time_rate >= 80
    return "Often pays late" if typical_days_from_due > 7

    "Mixed payment pattern"
  end

  def attention_segment
    return "Needs attention" if oldest_overdue_days.to_i >= 30
    return "Past due" if oldest_overdue_days.to_i.positive?
    return "On track" if outstanding_invoices.any?

    "Paid up"
  end

  def value_segment
    @value_segment
  end

  def value_segment=(value)
    @value_segment = value
  end

  def primary_currency
    currencies = invoices.filter_map { |invoice| invoice.currency.presence }.uniq
    currencies.one? ? currencies.first : nil
  end

  def average_invoice_amount
    return unless primary_currency && invoices.any?

    invoices.sum { |invoice| invoice.total.to_d } / invoices.size
  end

  def reminder_recommendation
    return paid_up_recommendation if outstanding_invoices.none?
    return high_value_overdue_recommendation if overdue_invoices.any? && value_segment == "High value"
    return firm_overdue_recommendation if oldest_overdue_days.to_i >= 30
    return standard_overdue_recommendation if overdue_invoices.any?

    current_invoice_recommendation
  end

  private
    def paid_invoices_with_dates
      @paid_invoices_with_dates ||= paid_invoices.select { |invoice| invoice.paid_on && invoice.due_on }
    end

    def payment_delay_days
      @payment_delay_days ||= paid_invoices_with_dates.map { |invoice| payment_delay_for(invoice) }
    end

    def forecast_payment_delays
      @forecast_payment_delays ||= paid_invoices_with_dates
        .reject { |invoice| unusual_payment_dates.include?(invoice) }
        .map { |invoice| payment_delay_for(invoice) }
    end

    def payment_delay_for(invoice)
      (invoice.paid_on - invoice.due_on).to_i
    end

    def median(values)
      return if values.empty?

      sorted_values = values.sort
      midpoint = sorted_values.length / 2
      return sorted_values.fetch(midpoint) if sorted_values.length.odd?

      ((sorted_values.fetch(midpoint - 1) + sorted_values.fetch(midpoint)) / 2.0).round
    end

    def totals_for(invoice_list)
      invoice_list.each_with_object(Hash.new(0.to_d)) do |invoice, totals|
        totals[invoice.currency.presence || "Unspecified"] += yield(invoice).to_d
      end
    end

    def paid_up_recommendation
      {
        name: "No reminder needed",
        tone: "None",
        timing: "No action",
        reason: "This customer has no outstanding balance."
      }
    end

    def high_value_overdue_recommendation
      {
        name: "Personal high-value follow-up",
        tone: "Direct, specific, and human",
        timing: "Review and send now",
        reason: "The balance is overdue and this customer sits in the account's high-value group."
      }
    end

    def firm_overdue_recommendation
      {
        name: "Firm overdue follow-up",
        tone: relationship_segment == "New customer" ? "Concise and firm" : "Personal and firm",
        timing: "Send now; follow up in 3 days",
        reason: "The oldest unpaid invoice is #{oldest_overdue_days} days past due."
      }
    end

    def standard_overdue_recommendation
      {
        name: "Standard overdue follow-up",
        tone: "Clear and courteous",
        timing: "Send now; follow up in 5 days",
        reason: "The customer has an overdue balance, but it is still within the first 30 days."
      }
    end

    def current_invoice_recommendation
      {
        name: value_segment == "High value" ? "Personal pre-due check-in" : "Standard pre-due reminder",
        tone: value_segment == "High value" ? "Personal and helpful" : "Brief and helpful",
        timing: "3 days before the next due date",
        reason: "The balance is current, so a light reminder is enough."
      }
    end
end
