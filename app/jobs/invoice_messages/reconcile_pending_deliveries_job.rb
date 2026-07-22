class InvoiceMessages::ReconcilePendingDeliveriesJob < ApplicationJob
  include Sentry::Cron::MonitorCheckIns

  STALE_AFTER = 2.hours
  FAILURE_REASON = "Delivery confirmation timed out."

  queue_as :default

  sentry_monitor_check_ins(
    slug: "reconcile-pending-invoice-messages",
    monitor_config: Sentry::Cron::MonitorConfig.from_interval(
      1,
      :hour,
      checkin_margin: 10,
      max_runtime: 30
    )
  )

  def perform
    cutoff = STALE_AFTER.ago
    reconciled_count = 0

    InvoiceMessage.stale_pending_deliveries(before: cutoff).find_each do |message|
      if message.reconcile_stale_delivery!(before: cutoff, failure_reason: FAILURE_REASON)
        reconciled_count += 1
      end
    end

    Rails.logger.warn(
      "invoice_message.pending_deliveries_reconciled " \
        "cutoff=#{cutoff.iso8601} count=#{reconciled_count}"
    ) if reconciled_count.positive?
  end
end
