class PaymentPromises::FollowUpLog
  WARNING_SKIP_REASONS = %w[
    delivery_state_changed
    missing_email
    missing_outbound_email_connection
    sender_address_mismatch
  ].freeze

  class << self
    def resolved(payment_promise:, resolution:)
      return unless resolution.in?(%i[fulfilled cancelled])

      log(
        :info,
        "payment_promise.#{resolution}",
        payment_promise:
      )
    end

    def skipped(payment_promise:, reason:, context: {}, level: nil)
      reason ||= "unknown_reason"
      level ||= reason.in?(WARNING_SKIP_REASONS) ? :warn : :info
      log(
        level,
        "payment_promise.follow_up_skipped",
        payment_promise:,
        reason:,
        **context
      )
    end

    def completed(payment_promise:, delivered:)
      log(
        delivered ? :info : :error,
        "payment_promise.follow_up_#{delivered ? "succeeded" : "failed"}",
        payment_promise:
      )
    end

    private
      def log(level, event, payment_promise:, **context)
        details = {
          account_id: payment_promise.account_id,
          invoice_id: payment_promise.invoice_id,
          payment_promise_id: payment_promise.id
        }.merge(context).map { |key, value| "#{key}=#{value}" }.join(" ")
        Rails.logger.public_send(level, "#{event} #{details}")
      end
  end
end
