class InvoiceReminders::SendJob < ApplicationJob
  queue_as :default

  retry_on OutboundEmailConnection::Errors::TemporaryDeliveryError,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_temporary_failure, error)
    end

  retry_on InvoiceReminders::InvoiceFreshnessCheck::Error,
    InvoiceSources::Xero::OauthClient::Error,
    InvoiceSources::Stripe::ApiClient::Error,
    wait: :polynomially_longer,
    attempts: 5

  limits_concurrency(
    to: 1,
    key: ->(invoice_id, *) { invoice_id.to_s },
    duration: 1.hour,
    on_conflict: :block
  )

  def perform(invoice_id, category, day_offset, _queued_tone)
    stage_key = "#{category}_#{day_offset}"
    invoice = find_invoice(invoice_id:, stage_key:)
    return unless invoice

    delivery_context = delivery_context_for(invoice:, category:, day_offset:, stage_key:)
    unless delivery_context
      cancel_pending_retry(invoice:, stage_key:)
      return
    end

    invoice = InvoiceReminders::InvoiceFreshnessCheck.call(invoice)
    delivery_context = delivery_context_for(invoice:, category:, day_offset:, stage_key:)
    unless delivery_context
      cancel_pending_retry(invoice:, stage_key:)
      return
    end

    stage, connection = delivery_context

    deliver_reminder(invoice:, stage:, connection:)
  end

  private
    def find_invoice(invoice_id:, stage_key:)
      invoice = Invoice.find_by(id: invoice_id)
      return invoice if invoice

      log_event(:warn, "invoice_reminder.skipped", reason: "missing_invoice", invoice_id:, stage_key:)
      nil
    end

    def delivery_context_for(invoice:, category:, day_offset:, stage_key:)
      connection = outbound_connection_for(invoice:, stage_key:)
      return unless connection
      return unless eligible_for_delivery?(invoice:, stage_key:)

      stage = current_stage_for(invoice:, category:, day_offset:)
      return unless stage
      return unless stage_available_for_delivery?(invoice:, stage:)
      return unless outside_follow_up_cooldown?(invoice:, stage_key:)
      return unless stage_due_today?(invoice:, stage:)
      return unless recipient_available?(invoice:, stage_key:)

      [ stage, connection ]
    end

    def eligible_for_delivery?(invoice:, stage_key:)
      unless invoice.account.automatic_invoice_reminders_enabled?
        log_skip(invoice:, stage_key:, reason: "disabled_account")
        return false
      end

      unless invoice.outstanding?
        log_skip(invoice:, stage_key:, reason: "not_outstanding")
        return false
      end

      true
    end

    def current_stage_for(invoice:, category:, day_offset:)
      payer_segment = invoice.customer.payer_segment
      stage = invoice.account.invoice_schedules.find_by(
        kind: payer_segment,
        category:,
        day_offset:
      )
      return stage if stage

      stage_key = "#{category}_#{day_offset}"
      log_skip(invoice:, stage_key:, reason: "stage_not_in_current_schedule", payer_segment:)
      nil
    end

    def stage_available_for_delivery?(invoice:, stage:)
      reminder = existing_reminder(invoice:, stage:)
      return true unless reminder
      return true if temporary_delivery_retry? && reminder.invoice_message.status_pending?

      log_skip(invoice:, stage_key: stage.key, reason: "duplicate_stage")
      false
    end

    def outside_follow_up_cooldown?(invoice:, stage_key:, lock: false)
      messages = invoice.invoice_messages.successful_outbound
      messages = messages.lock if lock
      return true unless messages.sent_after(InvoiceMessage::FOLLOW_UP_COOLDOWN.ago).exists?

      log_skip(invoice:, stage_key:, reason: "recent_outbound_message")
      false
    end

    def stage_due_today?(invoice:, stage:)
      return true if invoice.due_on == stage.invoice_due_on_for(reminder_on: Date.current)

      log_skip(invoice:, stage_key: stage.key, reason: "stage_not_due", due_on: invoice.due_on || "none")
      false
    end

    def recipient_available?(invoice:, stage_key:)
      return true if invoice.customer.reminder_email_addresses.any?

      log_skip(
        :warn,
        invoice:,
        stage_key:,
        reason: "missing_email",
        customer_id: invoice.customer_id
      )
      false
    end

    def outbound_connection_for(invoice:, stage_key:)
      account = invoice.account.reload
      connection = account.outbound_email_connection&.reload

      unless connection&.active? && connection.account_id == account.id
        log_skip(:warn, invoice:, stage_key:, reason: "missing_outbound_email_connection")
        return
      end

      unless connection.sender_matches?(account.invoice_reminder_from_email)
        log_skip(:warn, invoice:, stage_key:, reason: "sender_address_mismatch")
        return
      end

      connection
    end

    def deliver_reminder(invoice:, stage:, connection:)
      terminal = stage.category_overdue? && stage.terminal?
      mail_message = reminder_email(invoice:, stage:)
      reminder = reserve_delivery(invoice:, stage:, mail_message:)
      return unless reminder

      @outbound_connection = connection
      @mail_message = mail_message
      email_sent, delivery_result, failure_reason = send_email_result(invoice:, stage:)

      record_delivery_result(
        reminder:,
        email_sent:,
        delivery_result:,
        failure_reason:
      )
      log_delivery(invoice:, stage:, email_sent:)
      notify_account_users(invoice:, reminder:, terminal:) if email_sent
    ensure
      @mail_message = nil
      @outbound_connection = nil
    end

    def reserve_delivery(invoice:, stage:, mail_message:)
      reminder = nil

      invoice.with_lock do
        existing = existing_reminder(invoice:, stage:)
        if existing
          if temporary_delivery_retry? && existing.invoice_message.status_pending?
            reminder = existing
          else
            log_skip(invoice:, stage_key: stage.key, reason: "duplicate_stage")
          end
          next
        end

        next unless outside_follow_up_cooldown?(invoice:, stage_key: stage.key, lock: true)

        if invoice.invoice_messages.direction_outbound.status_pending.lock.exists?
          log_skip(invoice:, stage_key: stage.key, reason: "outbound_delivery_in_progress")
          next
        end

        message = invoice.invoice_messages.create!(
          invoice_message_attributes(invoice:, mail_message:)
        )
        reminder = invoice.invoice_reminders.create!(
          account: invoice.account,
          invoice_message: message,
          invoice_schedule: stage,
          category: stage.category,
          day_offset: stage.day_offset,
          stage_key: stage.key,
          tone: stage.tone.to_s
        )
      end

      reminder
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique
      log_skip(invoice:, stage_key: stage.key, reason: "delivery_reservation_conflict")
      nil
    end

    def invoice_message_attributes(invoice:, mail_message:)
      {
        account: invoice.account,
        direction: :outbound,
        kind: :scheduled_reminder,
        status: :pending,
        from_address: Array(mail_message.from).first,
        to_addresses: Array(mail_message.to),
        cc_addresses: Array(mail_message.cc),
        subject: mail_message.subject,
        body: message_body(mail_message)
      }
    end

    def message_body(mail_message)
      if mail_message.multipart?
        mail_message.text_part&.body&.decoded.presence ||
          mail_message.html_part&.body&.decoded.to_s
      else
        mail_message.body.decoded
      end
    end

    def record_delivery_result(reminder:, email_sent:, delivery_result:, failure_reason:)
      attributes = if email_sent
        {
          status: :sent,
          sent_at: Time.current,
          provider_message_id: provider_message_id(delivery_result),
          provider_thread_id: provider_thread_id(delivery_result),
          failure_reason: nil
        }
      else
        {
          status: :failed,
          sent_at: nil,
          provider_message_id: nil,
          provider_thread_id: nil,
          failure_reason:
        }
      end

      reminder.invoice_message.update!(attributes)
    end

    def log_delivery(invoice:, stage:, email_sent:)
      log_event(
        email_sent ? :info : :error,
        "invoice_reminder.delivery_#{email_sent ? "succeeded" : "failed"}",
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        stage_key: stage.key
      )
    end

    def notify_account_users(invoice:, reminder:, terminal:)
      InvoiceReminders::Notifier.deliver(invoice:, reminder:, terminal:)
    end

    def send_email_result(invoice:, stage:)
      result = send_email(invoice:, stage:)
      [ result.present?, result, result.present? ? nil : "Email provider did not confirm delivery." ]
    rescue OutboundEmailConnection::Errors::TemporaryDeliveryError
      raise
    rescue OutboundEmailConnection::Errors::AuthenticationError => error
      report_gmail_authentication_failure(error, invoice:)
      [ false, nil, error.message ]
    rescue StandardError => error
      [ false, nil, error.message ]
    end

    def report_gmail_authentication_failure(error, invoice:)
      Sentry.capture_exception(
        error,
        tags: {
          provider: "gmail",
          operation: "invoice_reminder_delivery"
        },
        extra: {
          account_id: invoice.account_id,
          invoice_id: invoice.id
        }
      )
    end

    def send_email(invoice:, stage:)
      message = @mail_message || reminder_email(invoice:, stage:)
      OutboundEmailConnection::Delivery.new(
        account: invoice.account,
        connection: @outbound_connection
      ).deliver(message)
    end

    def reminder_email(invoice:, stage:)
      InvoiceReminderMailer.reminder(invoice, stage).message
    end

    def record_exhausted_temporary_failure(error)
      invoice_id, category, day_offset, = arguments
      invoice = Invoice.find_by(id: invoice_id)
      return unless invoice

      stage_key = "#{category}_#{day_offset}"
      reminder = invoice.invoice_reminders.includes(:invoice_message).find_by(stage_key:)
      return unless reminder&.invoice_message&.status_pending?

      reminder.invoice_message.update!(status: :failed, failure_reason: error.message)
      log_event(
        :error,
        "invoice_reminder.delivery_failed",
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        stage_key:
      )
    end

    def cancel_pending_retry(invoice:, stage_key:)
      return unless temporary_delivery_retry?

      reminder = invoice.invoice_reminders.includes(:invoice_message).find_by(stage_key:)
      return unless reminder&.invoice_message&.status_pending?

      reminder.invoice_message.update!(
        status: :failed,
        failure_reason: "Reminder was no longer eligible (#{@last_skip_reason || "unknown_reason"})."
      )
    end

    def existing_reminder(invoice:, stage:)
      invoice.invoice_reminders
        .includes(:invoice_message)
        .where("stage_key = :stage_key OR invoice_schedule_id = :schedule_id", stage_key: stage.key, schedule_id: stage.id)
        .first
    end

    def temporary_delivery_retry?
      exception_executions[
        [ OutboundEmailConnection::Errors::TemporaryDeliveryError ].to_s
      ].to_i.positive?
    end

    def provider_message_id(delivery_result)
      return delivery_result.provider_message_id if delivery_result.respond_to?(:provider_message_id)
      return delivery_result if delivery_result.is_a?(String)

      nil
    end

    def provider_thread_id(delivery_result)
      return delivery_result.provider_thread_id if delivery_result.respond_to?(:provider_thread_id)

      nil
    end

    def log_skip(level = :info, invoice:, stage_key:, reason:, **context)
      @last_skip_reason = reason
      log_event(
        level,
        "invoice_reminder.skipped",
        reason:,
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        **context,
        stage_key:
      )
    end

    def log_event(level, event, **context)
      details = context.map { |key, value| "#{key}=#{value}" }.join(" ")
      Rails.logger.public_send(level, "#{event} #{details}")
    end
end
