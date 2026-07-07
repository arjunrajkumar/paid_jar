class Invoices::RefreshJob < ApplicationJob
  queue_as :default

  retry_on InvoiceSources::Stripe::OauthClient::Error,
    InvoiceSources::Xero::OauthClient::Error,
    wait: :polynomially_longer,
    attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(invoice)
    return if invoice.invoice_source.disconnected?

    invoice.invoice_source.sync_invoice!(external_id: invoice.external_id)
  end
end
