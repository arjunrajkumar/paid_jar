class InvoiceReminders::DeliveryReservation
  Result = Data.define(
    :reminder,
    :stage,
    :connection,
    :mail_message,
    :reason,
    :context
  ) do
    def reserved?
      reminder.present?
    end
  end

  def self.call(invoice:, category:, day_offset:, delivery_job_id:, on: Date.current)
    new(
      invoice:,
      category:,
      day_offset:,
      delivery_job_id:,
      on:
    ).call
  end

  def initialize(invoice:, category:, day_offset:, delivery_job_id:, on:)
    @invoice = invoice
    @category = category
    @day_offset = day_offset
    @delivery_job_id = delivery_job_id
    @on = on
  end

  def call
    reservation = nil

    invoice.with_lock do
      decision = stage_decision
      unless decision.deliverable?
        persist_suppression(decision) if decision.suppression?
        reservation = skipped(decision)
        next
      end

      mail_message = InvoiceReminderMailer.reminder(invoice, decision.stage).message
      reminder = decision.reminder || reserve_new_reminder(decision, mail_message:)

      unless reminder
        reservation = skipped_reason(:outbound_delivery_in_progress, stage: decision.stage)
        next
      end

      if decision.reminder && !reminder.invoice_message.refresh_delivery_attempt!(
        job_id: delivery_job_id,
        mail_message:
      )
        reservation = skipped_reason(:delivery_reservation_conflict, stage: decision.stage)
        next
      end

      reservation = Result.new(
        reminder:,
        stage: decision.stage,
        connection: decision.connection,
        mail_message:,
        reason: nil,
        context: {}
      )
    end

    reservation
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique
    skipped_reason(:delivery_reservation_conflict)
  end

  private
    attr_reader :invoice, :category, :day_offset, :delivery_job_id, :on

    def stage_decision
      InvoiceReminders::StageDecision.call(
        invoice:,
        category:,
        day_offset:,
        delivery_job_id:,
        on:
      )
    end

    def persist_suppression(decision)
      InvoiceReminderSuppression.record_for!(
        invoice:,
        stage: decision.stage,
        reason: decision.reason
      )
    end

    def reserve_new_reminder(decision, mail_message:)
      return if invoice.invoice_messages.direction_outbound.status_pending.lock.exists?

      message = invoice.invoice_messages.create!(
        {
          account: invoice.account,
          direction: :outbound,
          kind: :scheduled_reminder,
          status: :pending,
          delivery_job_id:,
          delivery_attempted_at: Time.current
        }.merge(InvoiceMessages::Content.from_mail(mail_message).attributes)
      )
      invoice.invoice_reminders.create!(
        account: invoice.account,
        invoice_message: message,
        invoice_schedule: decision.stage,
        category: decision.stage.category,
        day_offset: decision.stage.day_offset,
        stage_key: decision.stage.key,
        tone: decision.stage.tone.to_s
      )
    end

    def skipped(decision)
      Result.new(
        reminder: nil,
        stage: decision.stage,
        connection: nil,
        mail_message: nil,
        reason: decision.reason,
        context: decision.context
      )
    end

    def skipped_reason(reason, stage: nil)
      Result.new(
        reminder: nil,
        stage:,
        connection: nil,
        mail_message: nil,
        reason: reason.to_s,
        context: {}
      )
    end
end
