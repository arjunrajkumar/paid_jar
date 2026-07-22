class InvoiceSources::RefreshJob < ApplicationJob
  queue_as :default

  retry_on InvoiceSources::ProviderError,
    wait: :polynomially_longer,
    attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(invoice_source)
    return unless invoice_source.refreshable?

    invoice_source.sync_invoices!
  end
end
