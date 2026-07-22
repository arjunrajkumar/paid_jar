class PaymentPromises::ScheduleFollowUpsJob < ApplicationJob
  include Sentry::Cron::MonitorCheckIns

  queue_as :default

  sentry_monitor_check_ins(
    slug: "schedule-payment-promise-follow-ups",
    monitor_config: Sentry::Cron::MonitorConfig.from_interval(
      1,
      :hour,
      checkin_margin: 10,
      max_runtime: 30
    )
  )

  def perform
    PaymentPromise.due_for_follow_up.find_each do |payment_promise|
      PaymentPromises::FollowUpJob.perform_later(payment_promise.id)
    end
  end
end
