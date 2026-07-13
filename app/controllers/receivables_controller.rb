class ReceivablesController < ApplicationController
  def index
    @invoice_sources = InvoiceSource.connected_for(Current.account)
    invoices = Current.account.invoices.includes(:invoice_source).recent.to_a
    @has_synced_invoices = invoices.any?
    @dashboard = Receivables::Dashboard.new(invoices)
    @inbox_customers = Customers::Collection.new(invoices).profiles
  end
end
