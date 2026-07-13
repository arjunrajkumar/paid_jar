class Customers::Portfolio
  attr_reader :as_of, :customers

  def initialize(customers, as_of: Date.current)
    @customers = customers
    @as_of = as_of
  end

  def expected_next_30_days_totals
    totals_for(expected_next_30_days_invoices)
  end

  def expected_next_30_days_invoices
    invoice_entries.filter_map do |customer, invoice|
      expected_on = customer.expected_collection_on(invoice)
      invoice if expected_on&.in?(as_of..(as_of + 30.days))
    end
  end

  def past_expected_totals
    totals_for(past_expected_invoices)
  end

  def past_expected_invoices
    invoice_entries.filter_map do |customer, invoice|
      invoice if customer.past_expected_date?(invoice)
    end
  end

  def priorities(limit: nil)
    entries = customers.filter_map { |customer| priority_for(customer) }.sort_by { |entry| entry.fetch(:sort) }
    limit ? entries.first(limit) : entries
  end

  def today_priorities
    @today_priorities ||= priorities.select { |priority| priority.fetch(:timing) == "Today" }
  end

  def today_priority_totals
    today_priorities.each_with_object(Hash.new(0.to_d)) do |priority, totals|
      priority.fetch(:customer).outstanding_totals.each do |currency, amount|
        totals[currency] += amount
      end
    end
  end

  private
    def invoice_entries
      @invoice_entries ||= customers.flat_map do |customer|
        customer.outstanding_invoices.map { |invoice| [ customer, invoice ] }
      end
    end

    def totals_for(invoices)
      invoices.each_with_object(Hash.new(0.to_d)) do |invoice, totals|
        totals[invoice.currency.presence || "Unspecified"] += invoice.amount_due.to_d
      end
    end

    def priority_for(customer)
      expected_on = customer.next_expected_collection_on
      return unless expected_on

      if expected_on < as_of
        past_expected_priority(customer, expected_on)
      elsif customer.overdue_invoices.any?
        behavior_aware_priority(customer, expected_on)
      elsif expected_on <= as_of + 14.days
        upcoming_priority(customer, expected_on)
      end
    end

    def past_expected_priority(customer, expected_on)
      high_value = customer.value_segment == "High value"
      {
        customer: customer,
        action: high_value ? "Review high-value balance" : "Review overdue balance",
        timing: "Today",
        reason: "Expected by #{expected_on.strftime("%b %-d")}; #{customer.oldest_overdue_days} days overdue",
        tone: "red",
        sort: [ 0, high_value ? 0 : 1, high_value ? -sortable_balance(customer) : 0, expected_on, customer.name ]
      }
    end

    def behavior_aware_priority(customer, expected_on)
      {
        customer: customer,
        action: "Monitor expected payment",
        timing: expected_on.strftime("%b %-d"),
        reason: "Usually pays #{timing_description(customer.forecast_days_from_due)}",
        tone: "amber",
        sort: [ 1, expected_on, customer.name ]
      }
    end

    def upcoming_priority(customer, expected_on)
      {
        customer: customer,
        action: customer.value_segment == "High value" ? "Prepare personal reminder" : "Prepare reminder",
        timing: (expected_on - 3.days).strftime("%b %-d"),
        reason: "Expected #{expected_on.strftime("%b %-d")}; #{customer.forecast_basis.downcase}",
        tone: "slate",
        sort: [ 2, expected_on, customer.name ]
      }
    end

    def timing_description(days)
      return "on the due date" if days.to_i.zero?

      "#{days.abs} #{"day".pluralize(days.abs)} #{days.positive? ? "late" : "early"}"
    end

    def sortable_balance(customer)
      customer.outstanding_invoices.sum { |invoice| invoice.amount_due.to_d }
    end
end
