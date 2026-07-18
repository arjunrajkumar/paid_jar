# Production error reporting and scheduled-job monitoring.
# Kamal resolves the DSN from Rails credentials and injects it at runtime.
return unless Rails.env.production?
return if ENV["SENTRY_DSN"].blank?

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
  config.send_default_pii = false
  config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.05").to_f
  config.rails.active_job_report_on_retry_error = true

  release = ENV["SENTRY_RELEASE"].presence || ENV["KAMAL_VERSION"].presence
  config.release = release if release
end
