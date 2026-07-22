class PaymentPromises::DeliveryReservation
  Result = Data.define(
    :payment_promise,
    :message,
    :connection,
    :mail_message,
    :resolution,
    :reason,
    :context
  ) do
    def reserved?
      message.present? && mail_message.present?
    end

    def resolved?
      resolution.present?
    end
  end

  def self.call(payment_promise:, delivery_job_id:, on: Date.current)
    new(payment_promise:, delivery_job_id:, on:).call
  end

  def initialize(payment_promise:, delivery_job_id:, on:)
    @payment_promise = payment_promise
    @delivery_job_id = delivery_job_id
    @on = on
  end

  def call
    reservation = nil

    payment_promise.invoice.with_lock do
      payment_promise.reload
      decision = PaymentPromises::FollowUpDecision.for_delivery(
        payment_promise:,
        delivery_job_id:,
        on:
      )

      if decision.resolvable?
        payment_promise.resolve_follow_up!(as: decision.resolution)
        reservation = resolved(decision)
        next
      end

      unless decision.ready?
        reservation = skipped(decision)
        next
      end

      mail_message = PaymentPromiseMailer.follow_up(payment_promise).message
      message = decision.message || reserve_new_message(mail_message:)

      if decision.message && !message.refresh_delivery_attempt!(
        job_id: delivery_job_id,
        mail_message:
      )
        reservation = skipped_reason(:delivery_reservation_conflict)
        next
      end

      reservation = Result.new(
        payment_promise:,
        message:,
        connection: decision.connection,
        mail_message:,
        resolution: nil,
        reason: nil,
        context: {}
      )
    end

    reservation
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique
    skipped_reason(:delivery_reservation_conflict)
  end

  private
    attr_reader :payment_promise, :delivery_job_id, :on

    def reserve_new_message(mail_message:)
      message = payment_promise.invoice.invoice_messages.create!(
        {
          account: payment_promise.account,
          direction: :outbound,
          kind: :promise_follow_up,
          status: :pending,
          delivery_job_id:,
          delivery_attempted_at: Time.current
        }.merge(InvoiceMessages::Content.from_mail(mail_message).attributes)
      )
      payment_promise.update!(follow_up_message: message)
      message
    end

    def resolved(decision)
      Result.new(
        payment_promise:,
        message: decision.message,
        connection: nil,
        mail_message: nil,
        resolution: decision.resolution,
        reason: nil,
        context: decision.context
      )
    end

    def skipped(decision)
      Result.new(
        payment_promise:,
        message: decision.message,
        connection: nil,
        mail_message: nil,
        resolution: nil,
        reason: decision.reason,
        context: decision.context
      )
    end

    def skipped_reason(reason)
      Result.new(
        payment_promise:,
        message: nil,
        connection: nil,
        mail_message: nil,
        resolution: nil,
        reason: reason.to_s,
        context: {}
      )
    end
end
