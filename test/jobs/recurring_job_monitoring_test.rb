require "test_helper"

class RecurringJobMonitoringTest < ActiveJob::TestCase
  test "configures the reminder scheduler monitor for its hourly schedule" do
    assert_monitor_configuration(
      Account::InvoiceReminders::ScheduleJob,
      slug: "schedule-invoice-reminders",
      interval: 1,
      unit: :hour,
      checkin_margin: 10,
      max_runtime: 30
    )
  end

  test "configures the invoice source monitor for its six-hour schedule" do
    assert_monitor_configuration(
      InvoiceSources::RefreshAllJob,
      slug: "refresh-invoice-sources",
      interval: 6,
      unit: :hour,
      checkin_margin: 15,
      max_runtime: 15
    )
  end

  test "configures the pending delivery reconciler monitor for its hourly schedule" do
    assert_monitor_configuration(
      ConversationMessages::ReconcilePendingDeliveriesJob,
      slug: "reconcile-pending-conversation-messages",
      interval: 1,
      unit: :hour,
      checkin_margin: 10,
      max_runtime: 30
    )
  end

  test "configures the payment promise scheduler monitor for its hourly schedule" do
    assert_monitor_configuration(
      PaymentPromises::ScheduleFollowUpsJob,
      slug: "schedule-payment-promise-follow-ups",
      interval: 1,
      unit: :hour,
      checkin_margin: 10,
      max_runtime: 30
    )
  end

  test "reports a successful reminder scheduler execution" do
    monitor_config = Account::InvoiceReminders::ScheduleJob.sentry_monitor_config
    check_ins = sequence("check-ins")
    Account.stubs(:find_each)

    Sentry.expects(:capture_check_in)
      .with("schedule-invoice-reminders", :in_progress, monitor_config:)
      .returns("check-in-id")
      .in_sequence(check_ins)
    Sentry.expects(:capture_check_in)
      .with(
        "schedule-invoice-reminders",
        :ok,
        check_in_id: "check-in-id",
        duration: instance_of(Float),
        monitor_config:
      )
      .in_sequence(check_ins)

    Account::InvoiceReminders::ScheduleJob.perform_now
  end

  test "reports and reraises a failed reminder scheduler execution" do
    monitor_config = Account::InvoiceReminders::ScheduleJob.sentry_monitor_config
    check_ins = sequence("check-ins")
    failure = RuntimeError.new("scheduler failed")
    Account.stubs(:find_each).raises(failure)

    Sentry.expects(:capture_check_in)
      .with("schedule-invoice-reminders", :in_progress, monitor_config:)
      .returns("check-in-id")
      .in_sequence(check_ins)
    Sentry.expects(:capture_check_in)
      .with(
        "schedule-invoice-reminders",
        :error,
        check_in_id: "check-in-id",
        duration: instance_of(Float),
        monitor_config:
      )
      .in_sequence(check_ins)

    raised_error = assert_raises(RuntimeError) do
      Account::InvoiceReminders::ScheduleJob.perform_now
    end

    assert_same failure, raised_error
  end

  private
    def assert_monitor_configuration(job_class, slug:, interval:, unit:, checkin_margin:, max_runtime:)
      monitor_config = job_class.sentry_monitor_config

      assert_equal slug, job_class.sentry_monitor_slug
      assert_equal(
        { type: :interval, value: interval, unit: },
        monitor_config.schedule.to_h
      )
      assert_equal checkin_margin, monitor_config.checkin_margin
      assert_equal max_runtime, monitor_config.max_runtime
    end
end
