class InvoiceSources::RefreshJob < ApplicationJob
  queue_as :default

  limits_concurrency(
    to: 1,
    key: ->(invoice_source) { invoice_source },
    duration: 15.minutes,
    group: "InvoiceSourceSync",
    on_conflict: :block
  )

  retry_on InvoiceSources::ProviderError,
    wait: :polynomially_longer,
    attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(invoice_source)
    return unless invoice_source.refreshable?

    invoice_source.sync_invoices!
  end
end
