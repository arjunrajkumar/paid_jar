class InvoiceSources::RefreshJob < ApplicationJob
  queue_as :default

  retry_on InvoiceSources::Stripe::OauthClient::Error,
    InvoiceSources::Xero::OauthClient::Error,
    wait: :polynomially_longer,
    attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(invoice_source)
    return if invoice_source.disconnected?

    invoice_source.sync_invoices!
  end
end
