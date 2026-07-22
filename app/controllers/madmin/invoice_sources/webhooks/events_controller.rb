module Madmin
  class InvoiceSources::Webhooks::EventsController < Madmin::ResourceController
    def retry_processing
      unless @record.failed? || @record.pending?
        redirect_to resource.show_path(@record), alert: "Only pending or failed events can be retried."
        return
      end

      ::InvoiceSources::Webhooks::ProcessJob.perform_later(@record)
      redirect_to resource.show_path(@record), notice: "Webhook processing queued."
    end
  end
end
