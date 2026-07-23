module Madmin
  class EmailMessageReceiptsController < Madmin::ResourceController
    def retry_processing
      unless @record.retry!
        redirect_to resource.show_path(@record),
          alert: "Only terminally failed email receipts can be retried."
        return
      end

      begin
        ::EmailMessageReceipts::ProcessJob.enqueue(@record)
      rescue StandardError => error
        PlatformAdminEvent.record!(
          actor: Current.identity,
          action: "email_message_receipts.retry_processing_enqueue_failed",
          target: @record,
          account: @record.account,
          metadata: { error_class: error.class.name }
        )
        raise
      end

      redirect_to resource.show_path(@record), notice: "Email receipt processing queued."
    end
  end
end
