class InvoiceSources::RefreshAllJob < ApplicationJob
  queue_as :default

  def perform
    InvoiceSource.find_each do |invoice_source|
      InvoiceSources::RefreshJob.perform_later(invoice_source) if invoice_source.connected?
    end
  end
end
