module InvoiceSources
  class RefreshesController < ApplicationController
    before_action :set_invoice_source

    def create
      InvoiceSources::RefreshJob.perform_later(@invoice_source)
      redirect_to account_settings_path(script_name: Current.account.slug), notice: "#{invoice_source_name} invoice resync started."
    end

    private
      def set_invoice_source
        @invoice_source = Current.account.invoice_sources.find(params[:invoice_source_id])
        redirect_to account_settings_path(script_name: Current.account.slug), alert: "Connect an invoice source first." unless @invoice_source.connected?
      end

      def invoice_source_name
        @invoice_source.external_account_name.presence || @invoice_source.provider.titleize
      end
  end
end
