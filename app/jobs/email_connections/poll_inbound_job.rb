class EmailConnections::PollInboundJob < ApplicationJob
  include Sentry::Cron::MonitorCheckIns

  queue_as :default

  sentry_monitor_check_ins(
    slug: "poll-gmail-inbound",
    monitor_config: Sentry::Cron::MonitorConfig.from_interval(
      15,
      :minute,
      checkin_margin: 5,
      max_runtime: 10
    )
  )

  def perform
    EmailConnection.gmail.active.find_each do |connection|
      EmailConnections::SyncInboundJob.enqueue(connection) if connection.inbound_ready?
    end
  end
end
