require "test_helper"

class Account::InvoiceReminders::ScheduleAccountJobTest < ActiveJob::TestCase
  test "asks one account to enqueue its due reminders" do
    account = accounts(:paid_jar)
    account.expects(:enqueue_invoice_reminders)

    Account::InvoiceReminders::ScheduleAccountJob.perform_now(account)
  end

  test "limits scheduling concurrency per account" do
    account = accounts(:paid_jar)
    other_account = Account.create!(name: "Other Scheduling Account")
    first_job = Account::InvoiceReminders::ScheduleAccountJob.new(account)
    same_account_job = Account::InvoiceReminders::ScheduleAccountJob.new(account)
    other_account_job = Account::InvoiceReminders::ScheduleAccountJob.new(other_account)

    assert_predicate first_job, :concurrency_limited?
    assert_equal first_job.concurrency_key, same_account_job.concurrency_key
    refute_equal first_job.concurrency_key, other_account_job.concurrency_key
  end
end
