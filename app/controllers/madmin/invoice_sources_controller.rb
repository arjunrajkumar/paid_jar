module Madmin
  class InvoiceSourcesController < Madmin::ResourceController
    def refresh
      unless @record.refreshable?
        redirect_to resource.show_path(@record), alert: "This invoice source cannot be refreshed."
        return
      end

      ::InvoiceSources::RefreshJob.perform_later(@record)
      redirect_to resource.show_path(@record), notice: "Invoice refresh queued."
    end

    def disconnect
      if @record.xero?
        ::InvoiceSources::Xero.new(@record).disconnect!
      else
        @record.disconnect!
      end

      redirect_to resource.show_path(@record), notice: "Invoice source disconnected."
    rescue ::InvoiceSources::Xero::OauthClient::Error, ::InvoiceSources::Xero::DisconnectError => error
      redirect_to resource.show_path(@record), alert: "Disconnect failed: #{error.message}"
    end
  end
end
