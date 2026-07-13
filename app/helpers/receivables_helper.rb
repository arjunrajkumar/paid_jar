module ReceivablesHelper
  def receivable_amount(amount, currency)
    number_to_currency(
      amount || 0,
      unit: currency.present? ? "#{currency} " : "",
      precision: 2,
      strip_insignificant_zeros: true
    )
  end

  def receivable_totals(totals)
    return "0" if totals.empty?

    safe_join(
      totals.sort.map do |currency, amount|
        tag.span(receivable_amount(amount, currency), class: "app-currency-total")
      end,
      tag.br
    )
  end

  def receivable_due_date(invoice)
    invoice.due_on ? I18n.l(invoice.due_on, format: "%b %-d, %Y") : "No due date"
  end

  def receivables_sync_status(invoice_sources)
    last_synced_at = invoice_sources.filter_map(&:last_synced_at).max
    return "Connected" unless last_synced_at

    "Synced #{time_ago_in_words(last_synced_at)} ago"
  end

  def collection_priority_explanation(customer)
    [
      customer.value_segment,
      customer.relationship_segment.downcase,
      customer_payment_pattern(customer)
    ].join(" · ")
  end

  def invoice_overview_configuration(status, collection_filter: nil)
    filtered_configuration = {
      "expected" => { amount_label: "Balance", amount_method: :amount_due, status: nil, tone: nil, empty: "No payments are expected in the next 30 days." },
      "at_risk" => { amount_label: "Balance", amount_method: :amount_due, status: "Overdue", tone: "red", empty: "No invoices are past their expected date." },
      "collected" => { amount_label: "Total", amount_method: :total, status: "Paid", tone: "slate", empty: "No invoices have been collected this month." }
    }[collection_filter]
    return filtered_configuration if filtered_configuration

    {
      "overdue" => { amount_label: "Balance", amount_method: :amount_due, status: "Overdue", tone: "red", empty: "Nothing is overdue." },
      "current" => { amount_label: "Balance", amount_method: :amount_due, status: "Current", tone: "green", empty: "No invoices are currently awaiting payment." },
      "paid" => { amount_label: "Total", amount_method: :total, status: "Paid", tone: "slate", empty: "No paid invoices yet." }
    }.fetch(status)
  end

  def receivable_invoice_status(invoice, as_of: Date.current)
    if invoice.status.to_s.casecmp?("PAID") || (invoice.amount_due.to_d.zero? && invoice.amount_paid.to_d.positive?)
      { label: "Paid", tone: "slate" }
    elsif invoice.due_on && invoice.due_on < as_of
      { label: "Overdue", tone: "red" }
    else
      { label: "Current", tone: "green" }
    end
  end

  private
    def customer_payment_pattern(customer)
      days = customer.typical_days_from_due
      return "no paid history" if days.nil?
      return "usually pays on the due date" if days.zero?

      "usually pays #{days.abs} #{"day".pluralize(days.abs)} #{days.positive? ? "late" : "early"}"
    end
end
