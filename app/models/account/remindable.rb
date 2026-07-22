module Account::Remindable
  extend ActiveSupport::Concern

  def enqueue_invoice_reminders
    return unless automatic_invoice_reminders_enabled?

    delivery_availability = EmailConnection::DeliveryAvailability.call(account: self)
    return unless delivery_availability.ready?

    invoice_schedules.find_each do |schedule|
      enqueue_reminders(schedule:, delivery_availability:)
    end
  end

  private
    def enqueue_reminders(schedule:, delivery_availability:)
      invoices_needing_reminder(schedule:).find_each do |invoice|
        enqueue_or_suppress_reminder(invoice:, schedule:, delivery_availability:)
      end
    end

    def enqueue_or_suppress_reminder(invoice:, schedule:, delivery_availability:)
      invoice.with_lock do
        decision = InvoiceReminders::StageDecision.call(
          invoice:,
          category: schedule.category,
          day_offset: schedule.day_offset,
          delivery_availability:
        )

        if decision.suppression?
          InvoiceReminderSuppression.record_for!(
            invoice:,
            stage: decision.stage,
            reason: decision.reason
          )
        elsif decision.deliverable?
          InvoiceReminders::SendJob.perform_later(
            invoice.id,
            decision.stage.category.to_s,
            decision.stage.day_offset,
            decision.stage.tone.to_s
          )
        end
      end
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique
      nil
    end

    def invoices_needing_reminder(schedule:)
      invoices
        .outstanding
        .joins(customer: :customer_segment)
        .where(customer_segments: { payer_segment: schedule.kind })
        .where(due_on: schedule.invoice_due_on_for(reminder_on: Date.current))
        .where.not(
          id: InvoiceReminder.where(invoice_schedule: schedule).select(:invoice_id)
        )
        .where.not(
          id: InvoiceReminder.where(stage_key: schedule.key).select(:invoice_id)
        )
        .where.not(
          id: InvoiceReminderSuppression.where(invoice_schedule: schedule).select(:invoice_id)
        )
        .where.not(
          id: InvoiceReminderSuppression.where(stage_key: schedule.key).select(:invoice_id)
        )
    end
end
