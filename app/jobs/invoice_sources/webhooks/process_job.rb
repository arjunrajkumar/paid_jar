class InvoiceSources::Webhooks::ProcessJob < ApplicationJob
  queue_as :webhooks

  limits_concurrency(
    to: 1,
    key: ->(webhook_event) { webhook_event.invoice_source },
    duration: 15.minutes,
    group: "InvoiceSourceSync",
    on_conflict: :block
  )

  retry_on InvoiceSources::ProviderError,
    wait: :polynomially_longer,
    attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(webhook_event)
    webhook_event.process!
  end
end
