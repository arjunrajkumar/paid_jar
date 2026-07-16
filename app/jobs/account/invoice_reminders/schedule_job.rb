class Account::InvoiceReminders::ScheduleJob < ApplicationJob
  queue_as :default

  def perform
    Account.find_each do |account|
      account.enqueue_invoice_reminders
    end
  end
end
