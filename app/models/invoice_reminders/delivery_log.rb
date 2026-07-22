class InvoiceReminders::DeliveryLog
  WARNING_SKIP_REASONS = %w[
    delivery_state_changed
    missing_email
    missing_outbound_email_connection
    sender_address_mismatch
  ].freeze

  class << self
    def missing_invoice(invoice_id:, stage_key:)
      log(
        :warn,
        "invoice_reminder.skipped",
        reason: "missing_invoice",
        invoice_id:,
        stage_key:
      )
    end

    def skipped(invoice:, stage_key:, reason:, context: {}, level: nil)
      reason ||= "unknown_reason"
      level ||= reason.in?(WARNING_SKIP_REASONS) ? :warn : :info
      log(
        level,
        "invoice_reminder.skipped",
        reason:,
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        **context,
        stage_key:
      )
    end

    def completed(invoice:, stage_key:, delivered:)
      log(
        delivered ? :info : :error,
        "invoice_reminder.delivery_#{delivered ? "succeeded" : "failed"}",
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        stage_key:
      )
    end

    private
      def log(level, event, **context)
        details = context.map { |key, value| "#{key}=#{value}" }.join(" ")
        Rails.logger.public_send(level, "#{event} #{details}")
      end
  end
end
