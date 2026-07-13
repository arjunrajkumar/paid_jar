module CommunicationPreviewsHelper
  INBOX_STATE_PRIORITY = {
    reply: 0,
    dispute: 1,
    no_reply: 2,
    waiting: 3,
    outgoing: 3,
    scheduled: 3,
    monitoring: 4,
    not_contacted: 4,
    paid_up: 5
  }.freeze

  def communication_preview_for(customer)
    return paid_up_communication_preview(customer) if customer.outstanding_invoices.none?

    communication_previews.fetch(customer.name.to_s.squish.downcase) do
      {
        state: :not_contacted,
        status: "Not contacted",
        tone: "slate",
        headline: "No conversation yet",
        snippet: "Start a personal conversation when this account needs attention.",
        timestamp: nil,
        next_touch: "Review account",
        next_step: customer.reminder_recommendation.fetch(:name),
        action_label: "Review account",
        needs_attention: customer.overdue_invoices.any?,
        contact_email: customer.email
      }
    end
  end

  def customer_inbox_customers(customers)
    customers.sort_by { |customer| customer_inbox_sort_key(customer) }
  end

  def communication_contact_email(customer)
    customer.email.presence || communication_preview_for(customer).fetch(:contact_email, nil)
  end

  def collection_segment_for(customer)
    return inferred_collection_segment(customer) if customer.outstanding_invoices.none?

    collection_segments.fetch(customer.name.to_s.squish.downcase) { inferred_collection_segment(customer) }
  end

  def communication_thread_for(customer)
    preview = communication_preview_for(customer)
    invoice = customer.next_expected_invoice
    invoice_number = invoice&.number.presence || invoice&.external_id || "the open invoice"
    event_kind = communication_event_kind(preview.fetch(:state))

    return paid_up_thread(customer) if preview.fetch(:state) == :paid_up
    return reliable_retainer_thread(invoice_number) if customer.name.casecmp?("Reliable Retainer")
    return brightside_thread(invoice_number) if customer.name.casecmp?("Brightside Studio")

    [
      {
        kind: :system,
        label: "Invoice shared",
        timestamp: "Jul 3, 9:12 AM",
        body: "#{invoice_number} was emailed to #{communication_contact_email(customer) || "the billing contact"}."
      },
      {
        kind: event_kind,
        label: preview.fetch(:event_label, communication_event_label(event_kind, customer.name)),
        timestamp: preview.fetch(:timestamp) || "Today",
        body: preview.fetch(:thread_body, preview.fetch(:snippet))
      }
    ]
  end

  private
    def customer_inbox_sort_key(customer)
      preview = communication_preview_for(customer)

      [
        INBOX_STATE_PRIORITY.fetch(preview.fetch(:state), 4),
        customer.overdue_invoices.any? ? 0 : 1,
        -customer.oldest_overdue_days.to_i,
        customer.name.downcase
      ]
    end

    def paid_up_communication_preview(customer)
      {
        state: :paid_up,
        status: "Paid up",
        tone: "slate",
        headline: "No open balance",
        snippet: "No collection follow-up is needed while this account remains paid up.",
        timestamp: customer.last_payment_on ? "Paid #{customer.last_payment_on.strftime("%b %-d")}" : nil,
        next_touch: "None",
        next_step: "No action needed",
        action_label: "View account",
        needs_attention: false,
        contact_email: customer.email
      }
    end

    def communication_event_kind(state)
      case state
      when :waiting, :outgoing then :outgoing
      when :scheduled then :scheduled
      when :no_reply, :monitoring, :not_contacted, :paid_up then :system
      else :incoming
      end
    end

    def communication_event_label(kind, customer_name)
      case kind
      when :outgoing then "You replied"
      when :scheduled then "Scheduled message"
      when :system then "Collection activity"
      else customer_name
      end
    end

    def communication_previews
      {
        "nat dogre" => {
          state: :reply,
          status: "Customer replied",
          tone: "blue",
          headline: "Reply received 28 min ago",
          snippet: "Payment is being processed. Can you confirm the bank details we should use?",
          timestamp: "28 min ago",
          next_touch: "Now",
          next_step: "Reply with payment details",
          action_label: "Open reply",
          needs_attention: true,
          contact_email: "accounts@natdogre.example"
        },
        "brightside studio" => {
          state: :dispute,
          status: "Dispute raised",
          tone: "red",
          headline: "Invoice disputed 1 hr ago",
          snippet: "This amount does not match the scope we agreed for phase two.",
          timestamp: "1 hr ago",
          next_touch: "Now",
          next_step: "Review the dispute with the project owner",
          action_label: "Review dispute",
          needs_attention: true,
          contact_email: "billing@brightsidestudio.example"
        },
        "greenline foods" => {
          state: :waiting,
          status: "Awaiting customer",
          tone: "green",
          headline: "You replied 2 hr ago",
          snippet: "Thanks for checking. We sent the requested line-item breakdown and invited any follow-up questions.",
          thread_body: "Thanks for checking on this. We sent the line-item breakdown for the invoice and highlighted how the outstanding balance was calculated. Please reply if any line still needs clarification.",
          timestamp: "2 hr ago",
          next_touch: "When they reply",
          next_step: "Wait for the customer response",
          action_label: "View thread",
          needs_attention: false,
          contact_email: "ap@greenlinefoods.example"
        },
        "northstar consulting" => {
          state: :scheduled,
          status: "Scheduled",
          tone: "blue",
          headline: "Reminder scheduled",
          snippet: "A personal follow-up is queued for tomorrow at 9:00 AM.",
          timestamp: "Tomorrow, 9:00 AM",
          next_touch: "Tomorrow, 9:00 AM",
          next_step: "Review before it sends",
          action_label: "Review message",
          needs_attention: false,
          contact_email: "finance@northstar.example"
        },
        "harbor & co" => {
          state: :no_reply,
          status: "No reply",
          tone: "amber",
          headline: "No reply after 3 reminders",
          snippet: "The last reminder was opened 6 days ago, but no one has responded.",
          timestamp: "6 days ago",
          next_touch: "Today",
          next_step: "Escalate to a person",
          action_label: "Review escalation",
          needs_attention: true,
          contact_email: "accounts@harborco.example"
        },
        "slow payer co" => {
          state: :monitoring,
          status: "Monitoring",
          tone: "slate",
          headline: "No message due yet",
          snippet: "Payment is expected Jul 15 based on this customer's usual timing.",
          timestamp: "Jul 15",
          next_touch: "Jul 15",
          next_step: "Check again Jul 15",
          action_label: "View account",
          needs_attention: false,
          contact_email: "billing@slowpayer.example"
        },
        "reliable retainer" => {
          state: :scheduled,
          status: "Scheduled",
          tone: "blue",
          headline: "Pre-due check-in scheduled",
          snippet: "A personal check-in is ready to send Jul 22 at 9:00 AM if the invoice is still open.",
          timestamp: "Jul 22, 9:00 AM",
          next_touch: "Jul 22, 9:00 AM",
          next_step: "No action needed today",
          action_label: "Review scheduled message",
          needs_attention: false,
          contact_email: "billing@reliableretainer.example"
        },
        "pixelcraft labs" => {
          state: :scheduled,
          status: "Scheduled",
          tone: "blue",
          headline: "Standard pre-due reminder scheduled",
          snippet: "A brief, helpful reminder is queued for Jul 22, three days before the due date.",
          thread_body: "A brief, helpful reminder will send three days before the due date. No action will be requested if payment is already scheduled.",
          event_label: "Automatic reminder",
          timestamp: "Jul 22, 9:00 AM",
          next_touch: "Jul 22, 9:00 AM",
          next_step: "No action until Jul 22",
          action_label: "Review scheduled reminder",
          needs_attention: false,
          contact_email: "accounts@pixelcraft.example"
        }
      }
    end

    def collection_segments
      {
        "nat dogre" => segment(
          :new_high_value,
          "New high-value",
          "blue",
          "Personal and direct",
          "Human review",
          "High balance with no recorded payment history"
        ),
        "brightside studio" => segment(
          :disputed,
          "Disputed account",
          "red",
          "Empathetic and precise",
          "Automation paused",
          "Resolve the scope dispute before requesting payment"
        ),
        "greenline foods" => segment(
          :at_risk,
          "At risk",
          "red",
          "Clear and collaborative",
          "Human follow-up",
          "Long-overdue balance with an active customer enquiry"
        ),
        "harbor & co" => segment(
          :unresponsive,
          "Unresponsive",
          "amber",
          "Firm and concise",
          "Escalation only",
          "Repeated reminders were opened without a reply or payment"
        ),
        "northstar consulting" => segment(
          :at_risk,
          "At risk",
          "red",
          "Firm and courteous",
          "Scheduled follow-up",
          "The invoice is materially overdue with no paid history"
        ),
        "pixelcraft labs" => segment(
          :standard,
          "Standard cadence",
          "blue",
          "Brief and helpful",
          "Standard pre-due",
          "Current invoice with no exception requiring human review"
        ),
        "reliable retainer" => segment(
          :trusted,
          "Trusted payer",
          "green",
          "Warm and personal",
          "Low-frequency courtesy",
          "Consistently on time across the recorded relationship"
        ),
        "slow payer co" => segment(
          :habitually_late,
          "Habitually late",
          "amber",
          "Calm and specific",
          "Behavior-timed",
          "Usually pays late, so reminders follow their expected timing"
        )
      }
    end

    def inferred_collection_segment(customer)
      return segment(:paid_up, "Paid up", "slate", "No message needed", "None", "No outstanding balance") if customer.outstanding_invoices.none?
      return segment(:trusted, "Trusted payer", "green", "Warm and personal", "Low-frequency courtesy", "Strong on-time payment history") if customer.on_time_rate.to_i >= 90 && customer.payment_history_count >= 3
      return segment(:at_risk, "At risk", "red", "Clear and firm", "Human follow-up", "The oldest balance is more than 60 days overdue") if customer.oldest_overdue_days.to_i >= 60
      return segment(:new_high_value, "New high-value", "blue", "Personal and direct", "Human review", "High balance without enough payment history") if customer.value_segment == "High value"

      segment(:standard, "Standard cadence", "slate", "Brief and helpful", "Standard reminder", "No exceptional collection behavior detected")
    end

    def segment(key, name, tone, reply_tone, cadence, rationale)
      {
        key: key,
        name: name,
        tone: tone,
        reply_tone: reply_tone,
        cadence: cadence,
        rationale: rationale
      }
    end

    def reliable_retainer_thread(invoice_number)
      [
        {
          kind: :system,
          label: "Invoice sent",
          timestamp: "Jul 3, 9:12 AM",
          body: "#{invoice_number} was delivered to billing@reliableretainer.example."
        },
        {
          kind: :incoming,
          label: "Reliable Retainer",
          timestamp: "Jul 3, 10:18 AM",
          body: "Thanks — everything is approved on our side for payment this month."
        },
        {
          kind: :scheduled,
          label: "Scheduled message",
          timestamp: "Jul 22, 9:00 AM",
          body: "A personal pre-due check-in will send only if the invoice is still open."
        }
      ]
    end

    def paid_up_thread(customer)
      [
        {
          kind: :system,
          label: "Account paid up",
          timestamp: customer.last_payment_on ? customer.last_payment_on.strftime("%b %-d, %Y") : "Recorded payment history",
          body: "No open balance remains, so no collection follow-up is needed."
        }
      ]
    end

    def brightside_thread(invoice_number)
      [
        {
          kind: :system,
          label: "Invoice sent",
          timestamp: "Jun 1, 9:12 AM",
          body: "#{invoice_number} was delivered to billing@brightsidestudio.example."
        },
        {
          kind: :incoming,
          label: "Brightside Studio",
          timestamp: "1 hr ago",
          body: "This amount does not match the scope we agreed for phase two."
        },
        {
          kind: :outgoing,
          label: "Automatic acknowledgement",
          timestamp: "55 min ago",
          body: "Thanks for flagging this. We have paused payment reminders while our team checks the phase-two scope. We will reply with a clear breakdown before any further collection follow-up."
        }
      ]
    end
end
