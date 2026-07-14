module ReceivablesHelper
  CUSTOMER_INVOICE_STATUSES = {
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

  def customer_invoice_status(customer)
    CUSTOMER_INVOICE_STATUSES.fetch(customer_invoice_status_key(customer))
  end

  def customer_payer_profile(customer)
    Customers::PayerProfile.new(customer).to_h
  end

  def customer_invoice_due_context(invoice, as_of: Date.current)
    return "No due date" unless invoice&.due_on

    difference = (invoice.due_on - as_of).to_i
    return "Due today" if difference.zero?
    return "Due in #{pluralize(difference, "day")}" if difference.positive?

    "#{pluralize(difference.abs, "day")} overdue"
  end

  private
    def customer_invoice_status_key(customer)
      return :overdue if customer.overdue_invoices.any?
      return :outstanding if customer.outstanding_invoices.any?
      return :uncollectible if customer.uncollectible_invoices.any?
      return :open if customer.open_invoices.any?

      :paid
    end
end
