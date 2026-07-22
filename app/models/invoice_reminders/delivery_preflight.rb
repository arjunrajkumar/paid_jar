class InvoiceReminders::DeliveryPreflight
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
    decision = stage_decision
    return decision unless decision.suppression?

    invoice.with_lock do
      decision = stage_decision
      if decision.suppression?
        InvoiceReminderSuppression.record_for!(
          invoice:,
          stage: decision.stage,
          reason: decision.reason
        )
      end
      decision
    end
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique
    stage_decision
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
end
