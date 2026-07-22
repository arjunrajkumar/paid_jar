class Account::InvoiceReminders::ScheduleAccountJob < ApplicationJob
  queue_as :default

  limits_concurrency(
    to: 1,
    key: ->(account) { account },
    duration: 15.minutes,
    on_conflict: :block
  )

  discard_on ActiveJob::DeserializationError

  def perform(account)
    account.enqueue_invoice_reminders
  end
end
