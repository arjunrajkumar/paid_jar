module CustomersHelper
  def customer_payment_timing(customer)
    days = customer.typical_days_from_due
    return "No paid history" if days.nil?
    return "On the due date" if days.zero?

    "#{pluralize(days.abs, "day")} #{days.positive? ? "late" : "early"}"
  end

  def customer_overdue_age(customer)
    customer.oldest_overdue_days ? pluralize(customer.oldest_overdue_days, "day") : "—"
  end

  def customer_invoice_date(date)
    date ? I18n.l(date, format: "%b %-d, %Y") : "—"
  end

  def customer_invoice_status(invoice, as_of: Date.current)
    if invoice.status.to_s.casecmp?("PAID") || (invoice.amount_due.to_d.zero? && invoice.amount_paid.to_d.positive?)
      { label: "Paid", tone: "slate" }
    elsif invoice.due_on && invoice.due_on < as_of
      { label: "Overdue", tone: "red" }
    else
      { label: "Current", tone: "green" }
    end
  end

  def customer_attention_tone(customer)
    case customer.attention_segment
    when "Needs attention", "Past due" then "red"
    when "On track" then "green"
    else "slate"
    end
  end

  def customer_action_state(customer)
    return :paid_up if customer.outstanding_invoices.none?

    invoice = customer.next_expected_invoice
    return :review_now if invoice.due_on.blank? || invoice.due_on <= customer.as_of

    customer_planned_touch_date(customer) > customer.as_of ? :wait : :review_now
  end

  def customer_action_title(customer)
    case customer_action_state(customer)
    when :paid_up
      "No collection action needed"
    when :wait
      "Wait until #{I18n.l(customer_planned_touch_date(customer), format: "%b %-d")} before contacting this customer"
    else
      "Review this account today"
    end
  end

  def customer_action_summary(customer)
    return "This customer has no outstanding balance." if customer.outstanding_invoices.none?

    invoice = customer.next_expected_invoice
    invoice_number = invoice.number.presence || invoice.external_id
    recommendation = customer.reminder_recommendation

    if customer_action_state(customer) == :wait
      "#{customer.name} #{customer_payment_habit(customer)}"
    elsif invoice.due_on.blank?
      "#{invoice_number} has no due date in the synced invoice data. Review the account before contacting the customer."
    elsif invoice.due_on && invoice.due_on < customer.as_of
      recommendation.fetch(:reason)
    else
      "#{invoice_number} remains open and its recommended check-in date has arrived."
    end
  end

  def customer_action_why(customer)
    facts = [ customer.value_segment, customer.relationship_segment.downcase ]
    facts << "#{customer_totals_text(customer.total_billed_totals)} billed in synced history"
    facts << customer_on_time_evidence(customer) if customer.on_time_rate
    facts.join(" · ")
  end

  def customer_planned_touch_date(customer)
    invoice = customer.next_expected_invoice
    return unless invoice
    return customer.as_of if invoice.due_on.blank? || invoice.due_on <= customer.as_of

    [ invoice.due_on - 3.days, customer.as_of ].max
  end

  def customer_planned_touch_label(customer)
    date = customer_planned_touch_date(customer)
    return "No touch planned" unless date
    return "Today" if date == customer.as_of

    I18n.l(date, format: "%b %-d, %Y")
  end

  def customer_contact_status(customer)
    if customer.email.present?
      { label: "Billing contact ready", detail: customer.email, tone: "green" }
    elsif customer.outstanding_invoices.none?
      provider = customer.invoice_source.provider.titleize
      { label: "Billing contact not available", detail: "No email was provided by #{provider}.", tone: "slate" }
    else
      provider = customer.invoice_source.provider.titleize
      { label: "Billing contact required", detail: "No email was provided by #{provider}.", tone: "amber" }
    end
  end

  def customer_invoice_due_context(invoice, as_of: Date.current)
    return "No due date" unless invoice.due_on

    difference = (invoice.due_on - as_of).to_i
    return "Due today" if difference.zero?
    return "Due in #{pluralize(difference, "day")}" if difference.positive?

    "#{pluralize(difference.abs, "day")} overdue"
  end

  def customer_expected_window_label(customer, invoice)
    window = customer.expected_collection_window(invoice)
    return "—" unless window
    return I18n.l(window.begin, format: "%b %-d, %Y") if window.begin == window.end

    if window.begin.year == window.end.year && window.begin.month == window.end.month
      "#{window.begin.strftime("%b %-d")}-#{window.end.strftime("%-d, %Y")}"
    else
      "#{window.begin.strftime("%b %-d, %Y")}-#{window.end.strftime("%b %-d, %Y")}"
    end
  end

  def customer_forecast_explanation(customer, invoice = nil)
    return "A payment estimate is unavailable because this invoice has no due date." if invoice&.due_on.blank?

    count = customer.comparable_payment_count
    case count
    when 0
      "No comparable payments are available, so the invoice due date is used."
    when 1
      "Only one comparable payment is available, so the estimated date is shown as a wider range."
    else
      "Based on #{pluralize(count, "comparable payment")}."
    end
  end

  def customer_forecast_confidence_label(customer, invoice = nil)
    return "Estimate unavailable" if invoice&.due_on.blank?

    customer.forecast_confidence == "Due date only" ? "Due date estimate" : "#{customer.forecast_confidence} confidence"
  end

  def customer_forecast_confidence_tone(customer, invoice = nil)
    return "slate" if invoice&.due_on.blank?

    case customer.forecast_confidence
    when "High" then "green"
    when "Medium", "Low" then "amber"
    else "slate"
    end
  end

  def customer_on_time_evidence(customer)
    return "No recorded payment history" if customer.on_time_rate.nil?

    "#{customer.on_time_rate}% on time across #{pluralize(customer.payment_history_count, "recorded payment")}"
  end

  def customer_payment_history_evidence(customer)
    return "No recorded payments in synced history" if customer.payment_history_count.zero?

    pluralize(customer.payment_history_count, "recorded payment")
  end

  def customer_suggested_message_subject(customer, invoice)
    segment = collection_segment_for(customer).fetch(:key)
    invoice_number = invoice.number.presence || invoice.external_id

    return "Re: question about invoice #{invoice_number}" if segment == :disputed
    return "Upcoming invoice #{invoice_number}" if segment == :trusted || segment == :standard

    prefix = invoice.due_on && invoice.due_on < customer.as_of ? "Follow-up" : "Quick check-in"
    "#{prefix} on invoice #{invoice_number}"
  end

  def customer_suggested_message_paragraphs(customer, invoice)
    invoice_number = invoice.number.presence || invoice.external_id
    amount = receivable_amount(invoice.amount_due, invoice.currency)
    due_date = invoice.due_on ? customer_invoice_date(invoice.due_on) : nil
    segment = collection_segment_for(customer).fetch(:key)

    case segment
    when :trusted
      return [
        "Just a friendly heads-up that invoice #{invoice_number} for #{amount} is due on #{due_date}.",
        "No action is needed if payment is already scheduled. As always, please reply if we can make anything easier."
      ]
    when :disputed
      return [
        "Thank you for flagging the question about invoice #{invoice_number}. We have paused payment reminders while we review the agreed scope.",
        "Our team is checking the details now and will reply with a clear breakdown before any further collection follow-up."
      ]
    when :new_high_value
      return [
        "I am checking in personally about invoice #{invoice_number} for #{amount}#{", due on #{due_date}" if due_date}.",
        "Could you confirm whether payment is in progress, or let me know if there is anything I can clarify?"
      ]
    when :unresponsive
      return [
        "Invoice #{invoice_number} still has an outstanding balance of #{amount}#{" and was due on #{due_date}" if due_date}.",
        "Please reply with the expected payment date today, or tell us who we should coordinate with to resolve this."
      ]
    when :at_risk
      return [
        "We are following up on invoice #{invoice_number}, which has an outstanding balance of #{amount}#{" and was due on #{due_date}" if due_date}.",
        "Please share the expected payment date, or let us know what information would help resolve the outstanding balance."
      ]
    when :habitually_late
      return [
        "A quick timing check on invoice #{invoice_number} for #{amount}#{", due on #{due_date}" if due_date}.",
        "Based on our previous payments, we are expecting this shortly. Please let us know if the timing has changed."
      ]
    end

    if invoice.due_on && invoice.due_on < customer.as_of
      first_paragraph = "A quick reminder that invoice #{invoice_number}, with an outstanding balance of #{amount}, was due on #{due_date}."
      second_paragraph = "Please let us know if payment is already in progress or if there is anything we can clarify."
    elsif due_date
      first_paragraph = "A quick check-in on invoice #{invoice_number} for #{amount}, due on #{due_date}."
      second_paragraph = "Please let us know if anything needs clarification before the due date."
    else
      first_paragraph = "A quick check-in on invoice #{invoice_number}, with an outstanding balance of #{amount}."
      second_paragraph = "Please let us know if payment is already in progress or if there is anything we can clarify."
    end

    [ first_paragraph, second_paragraph ]
  end

  def customer_average_invoice(customer)
    return "—" unless customer.average_invoice_amount

    receivable_amount(customer.average_invoice_amount, customer.primary_currency)
  end

  def customer_data_quality_description(invoice)
    days = (invoice.paid_on - invoice.due_on).to_i
    "#{invoice.number.presence || invoice.external_id} was recorded #{pluralize(days.abs, "day")} #{days.positive? ? "after" : "before"} its due date."
  end

  def customer_payment_event_label(event)
    days = event.fetch(:delay)
    return "On due date" if days.zero?

    "#{pluralize(days.abs, "day")} #{days.positive? ? "late" : "early"}"
  end

  def customer_payment_event_tone(event)
    return "green" if event.fetch(:delay) <= 0
    return "amber" if event.fetch(:delay) <= 7

    "red"
  end

  def customer_invoice_expected_date(customer, invoice)
    return "—" if customer_invoice_status(invoice, as_of: customer.as_of).fetch(:label) == "Paid"

    customer_expected_window_label(customer, invoice)
  end

  private
    def customer_payment_habit(customer)
      return "has no comparable paid history yet." if customer.typical_days_from_due.nil?

      "normally pays #{customer_payment_timing(customer).downcase}."
    end

    def customer_totals_text(totals)
      totals.sort.map { |currency, amount| receivable_amount(amount, currency) }.to_sentence
    end
end
