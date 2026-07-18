class InvoiceSources::RefreshAllJob < ApplicationJob
  include Sentry::Cron::MonitorCheckIns

  queue_as :default

  sentry_monitor_check_ins(
    slug: "refresh-invoice-sources",
    monitor_config: Sentry::Cron::MonitorConfig.from_interval(
      6,
      :hour,
      checkin_margin: 15,
      max_runtime: 15
    )
  )

  def perform
    InvoiceSource.find_each do |invoice_source|
      InvoiceSources::RefreshJob.perform_later(invoice_source) if invoice_source.connected?
    end
  end
end
