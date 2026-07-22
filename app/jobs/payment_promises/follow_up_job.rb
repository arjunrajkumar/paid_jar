class PaymentPromises::FollowUpJob < ApplicationJob
  queue_as :default

  retry_on EmailConnection::Errors::TemporaryDeliveryError,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_delivery_failure, error)
    end

  retry_on InvoiceReminders::InvoiceFreshnessCheck::Error,
    InvoiceSources::Xero::OauthClient::Error,
    InvoiceSources::Stripe::ApiClient::Error,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_delivery_failure, error)
      raise error
    end

  limits_concurrency(
    to: 1,
    key: ->(payment_promise_id) { payment_promise_id.to_s },
    duration: 1.hour,
    on_conflict: :block
  )

  def perform(payment_promise_id)
    payment_promise = PaymentPromise.find_by(id: payment_promise_id)
    return unless payment_promise

    decision = PaymentPromises::FollowUpDecision.before_refresh(payment_promise:)
    return unless proceed_after_preflight?(decision)

    InvoiceReminders::InvoiceFreshnessCheck.call(decision.invoice)
    reservation = PaymentPromises::DeliveryReservation.call(
      payment_promise: payment_promise.reload,
      delivery_job_id: job_id
    )
    unless reservation.reserved?
      handle_reservation_result(reservation)
      return
    end

    deliver_follow_up(payment_promise:, reservation:)
  end

  private
    def proceed_after_preflight?(decision)
      if decision.resolvable?
        apply_resolution(decision)
        false
      else
        decision.ready?
      end
    end

    def handle_reservation_result(reservation)
      if reservation.resolved?
        PaymentPromises::FollowUpLog.resolved(
          payment_promise: reservation.payment_promise,
          resolution: reservation.resolution
        )
      else
        PaymentPromises::FollowUpLog.skipped(
          payment_promise: reservation.payment_promise,
          reason: reservation.reason,
          context: reservation.context
        )
      end
    end

    def apply_resolution(decision)
      decision.payment_promise.resolve_follow_up!(as: decision.resolution)
      PaymentPromises::FollowUpLog.resolved(
        payment_promise: decision.payment_promise,
        resolution: decision.resolution
      )
    end

    def deliver_follow_up(payment_promise:, reservation:)
      delivery_result = ConversationMessages::ProviderDelivery.call(
        account: payment_promise.account,
        connection: reservation.connection,
        mail_message: reservation.mail_message,
        operation: "payment_promise_follow_up_delivery",
        context: {
          account_id: payment_promise.account_id,
          invoice_id: payment_promise.invoice_id,
          payment_promise_id: payment_promise.id
        }
      )
      recorded = record_delivery_result(
        payment_promise:,
        delivery_result:
      )

      unless recorded
        PaymentPromises::FollowUpLog.skipped(
          payment_promise:,
          reason: "delivery_state_changed"
        )
        return
      end

      PaymentPromises::FollowUpLog.completed(
        payment_promise:,
        delivered: delivery_result.confirmed?
      )
    end

    def record_delivery_result(payment_promise:, delivery_result:)
      if delivery_result.confirmed?
        payment_promise.record_follow_up_sent!(
          job_id:,
          sent_at: Time.current,
          provider_message_id: delivery_result.provider_message_id,
          provider_thread_id: delivery_result.provider_thread_id
        )
      else
        payment_promise.record_follow_up_failed!(
          job_id:,
          failure_reason: delivery_result.failure_reason
        )
      end
    end

    def record_exhausted_delivery_failure(error)
      payment_promise = PaymentPromise.find_by(id: arguments.first)
      return false unless payment_promise
      return false unless payment_promise.record_follow_up_failed!(
        job_id:,
        failure_reason: error.message
      )

      PaymentPromises::FollowUpLog.completed(
        payment_promise:,
        delivered: false
      )
      true
    end
end
