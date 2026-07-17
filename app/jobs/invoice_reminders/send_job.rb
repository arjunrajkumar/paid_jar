class InvoiceReminders::SendJob < ApplicationJob
  queue_as :default

  def perform(invoice_id, category, day_offset, tone)
    invoice = Invoice.find_by(id: invoice_id)
    return unless invoice
    return unless invoice.account.automatic_invoice_reminders_enabled?

    stage_key = "#{category}_#{day_offset}"
    return if invoice.invoice_reminders.exists?(stage_key:)

    email_sent, failure_reason = send_email_result(invoice:, stage_key:, tone:)

    invoice.invoice_reminders.create!(
      account: invoice.account,
      category:,
      day_offset:,
      stage_key:,
      status: email_sent ? :sent : :failed,
      sent_at: email_sent ? Time.current : nil,
      failure_reason:
    )

    return unless email_sent

    Rails.logger.info "Create notifications"
    Rails.logger.info "Create final-stage escalation notification" if tone == "final"
  end

  private
    def send_email_result(invoice:, stage_key:, tone:)
      [ send_email(invoice:, stage_key:, tone:), nil ]
    rescue StandardError => error
      [ false, error.message ]
    end

    def send_email(invoice:, stage_key:, tone:)
      true
    end
end
