module Madmin
  class PaymentPromisesController < Madmin::ResourceController
    def fulfill
      @record.fulfill!
      redirect_to resource.show_path(@record), notice: "Payment promise marked fulfilled."
    end

    def cancel
      @record.cancel!
      redirect_to resource.show_path(@record), notice: "Payment promise cancelled."
    end

    def enqueue_follow_up
      unless @record.status_active?
        redirect_to resource.show_path(@record), alert: "Only an active promise can be followed up."
        return
      end

      ::PaymentPromises::FollowUpJob.perform_later(@record.id)
      redirect_to resource.show_path(@record), notice: "Payment-promise follow-up check queued."
    end
  end
end
