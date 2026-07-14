module ReceivablesHelper
  RECEIVABLE_STATUSES = {
    overdue: { label: "Overdue", tone: "overdue" },
    outstanding: { label: "Outstanding", tone: "outstanding" },
    uncollectible: { label: "Uncollectible", tone: "uncollectible" },
    open: { label: "Open", tone: "open" },
    paid: { label: "Paid", tone: "paid" }
  }.freeze

  def receivable_amount(amount, currency)
    number_to_currency(
      amount || 0,
      unit: currency.present? ? "#{currency} " : "",
      precision: 2,
      strip_insignificant_zeros: true
    )
  end

  def receivable_totals(totals, qualifier: nil)
    return "0" if totals.empty?

    safe_join(
      totals.sort.map do |currency, amount|
        total = [ receivable_amount(amount, currency), qualifier.presence ].compact.join(" ")
        tag.span(total, class: "app-currency-total")
      end,
      tag.br
    )
  end

  def receivable_status(receivable, as_of: Date.current)
    RECEIVABLE_STATUSES.fetch(receivable.display_status(as_of: as_of))
  end

  def receivable_due_context(receivable, as_of: Date.current)
    return "No due date" unless receivable.due_on

    difference = (receivable.due_on - as_of).to_i
    return "Due today" if difference.zero?
    return "Due in #{pluralize(difference, "day")}" if difference.positive?

    "#{pluralize(difference.abs, "day")} overdue"
  end
end
