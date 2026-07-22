module Madmin
  class InvoicesController < Madmin::ResourceController
    def send_manual_reminder
      unless @record.outstanding?
        redirect_to resource.show_path(@record), alert: "Only an outstanding invoice can receive a reminder."
        return
      end

      ::InvoiceReminders::ManualSendJob.perform_later(@record.id)
      redirect_to resource.show_path(@record), notice: "Manual reminder queued."
    end

    def new_payment_promise
      @promised_on = Date.current
    end

    def record_payment_promise
      @promised_on = Date.iso8601(payment_promise_params.fetch(:promised_on))
      promise = ::PaymentPromises::ManualRecorder.call(
        invoice: @record,
        promised_on: @promised_on,
        note: payment_promise_params[:note]
      )

      redirect_to PaymentPromiseResource.show_path(promise), notice: "Payment promise recorded."
    rescue Date::Error, KeyError, ActiveRecord::RecordInvalid, ArgumentError => error
      flash.now[:alert] = error.message
      render :new_payment_promise, status: :unprocessable_entity
    end

    private
      def payment_promise_params
        params.expect(payment_promise: %i[promised_on note])
      end
  end
end
