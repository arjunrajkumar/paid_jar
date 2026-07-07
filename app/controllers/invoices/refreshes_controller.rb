module Invoices
  class RefreshesController < ApplicationController
    before_action :set_invoice

    def create
      Invoices::RefreshJob.perform_later(@invoice)
      redirect_to invoices_path, notice: "#{invoice_name} refresh started."
    end

    private
      def set_invoice
        @invoice = Current.account.invoices.includes(:invoice_source).find(params[:invoice_id])
        redirect_to invoice_sources_path, alert: "Reconnect the invoice source first." unless @invoice.invoice_source.connected?
      end

      def invoice_name
        "Invoice #{@invoice.number.presence || @invoice.external_id}"
      end
  end
end
