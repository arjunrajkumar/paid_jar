class Account::InvoiceReminders::ScheduleJob < ApplicationJob
  include Sentry::Cron::MonitorCheckIns

  queue_as :default

  sentry_monitor_check_ins(
    slug: "schedule-invoice-reminders",
    monitor_config: Sentry::Cron::MonitorConfig.from_interval(
      1,
      :hour,
      checkin_margin: 10,
      max_runtime: 30
    )
  )

  def perform
    Account.find_each do |account|
      account.enqueue_invoice_reminders
    end
  end
end
