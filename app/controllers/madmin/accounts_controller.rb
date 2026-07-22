module Madmin
  class AccountsController < Madmin::ResourceController
    def refresh_customer_segments
      @record.refresh_customer_segments!
      redirect_to resource.show_path(@record), notice: "Customer segments refreshed."
    end

    def enqueue_invoice_reminders
      ::Account::InvoiceReminders::ScheduleAccountJob.perform_later(@record)
      redirect_to resource.show_path(@record), notice: "Reminder scheduling queued for this account."
    end
  end
end
