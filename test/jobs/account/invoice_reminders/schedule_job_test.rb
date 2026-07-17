require "test_helper"

class Account::InvoiceReminders::ScheduleJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:paid_jar)
    @account.update!(automatic_invoice_reminders_enabled: true)
    @invoice_source = invoice_sources(:xero)
  end

  test "asks every account to enqueue its invoice reminders" do
    first_account = mock
    second_account = mock

    Account.expects(:find_each).multiple_yields([ first_account ], [ second_account ])
    first_account.expects(:enqueue_invoice_reminders)
    second_account.expects(:enqueue_invoice_reminders)

    Account::InvoiceReminders::ScheduleJob.perform_now
  end

  test "queues every policy stage due today for every debtor rating" do
    reminder_on = Date.new(2026, 11, 17)
    expected_jobs = []

    travel_to reminder_on.in_time_zone.change(hour: 12) do
      InvoiceReminder::Policy::SCHEDULES.each do |payer_segment, stages|
        customer = create_customer(payer_segment:)

        stages.each do |stage|
          invoice = create_invoice(
            customer:,
            due_on: stage.invoice_due_on_for(reminder_on:)
          )
          expected_jobs << [
            invoice.id,
            stage.category.to_s,
            stage.day_offset,
            stage.tone.to_s
          ]
        end
      end

      assert_enqueued_jobs expected_jobs.size, only: InvoiceReminders::SendJob do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end
    end

    actual_jobs = enqueued_jobs.filter_map do |job|
      job[:args] if job[:job] == InvoiceReminders::SendJob
    end

    assert_equal expected_jobs.sort, actual_jobs.sort
  end

  test "uses the exact target date and matching debtor rating" do
    reminder_on = Date.new(2026, 11, 17)

    travel_to reminder_on.in_time_zone.change(hour: 12) do
      good_customer = create_customer(payer_segment: :good_debtor)
      normal_customer = create_customer(payer_segment: :normal_debtor)

      create_invoice(customer: good_customer, due_on: reminder_on + 7.days)
      create_invoice(customer: normal_customer, due_on: reminder_on + 8.days)

      assert_no_enqueued_jobs only: InvoiceReminders::SendJob do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end
    end
  end

  test "does not queue reminders when the account has disabled them" do
    reminder_on = Date.new(2026, 11, 17)

    travel_to reminder_on.in_time_zone.change(hour: 12) do
      customer = create_customer(payer_segment: :good_debtor)
      create_invoice(customer:, due_on: reminder_on + 3.days)
      @account.update!(automatic_invoice_reminders_enabled: false)

      assert_no_enqueued_jobs only: InvoiceReminders::SendJob do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end
    end
  end

  test "scopes reminder selection to each account being processed" do
    reminder_on = Date.new(2026, 11, 17)
    other_account = Account.create!(name: "Other Reminder Account")
    other_invoice_source = other_account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "schedule-other-account"
    )

    travel_to reminder_on.in_time_zone.change(hour: 12) do
      current_customer = create_customer(payer_segment: :good_debtor)
      other_customer = create_customer(
        payer_segment: :good_debtor,
        account: other_account,
        invoice_source: other_invoice_source
      )
      current_invoice = create_invoice(customer: current_customer, due_on: reminder_on + 3.days)
      create_invoice(customer: other_customer, due_on: reminder_on + 3.days)

      Account.expects(:find_each).yields(@account)

      assert_enqueued_jobs 1, only: InvoiceReminders::SendJob do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end
      assert_enqueued_with(
        job: InvoiceReminders::SendJob,
        args: [ current_invoice.id, "pre_due", 3, "friendly" ]
      )
    end
  end

  test "uses the customer's current rating without backfilling earlier stages" do
    reminder_on = Date.new(2026, 11, 17)

    travel_to reminder_on.in_time_zone.change(hour: 12) do
      customer = create_customer(payer_segment: :normal_debtor)
      normal_invoice = create_invoice(customer:, due_on: reminder_on - 7.days)

      assert_enqueued_with(
        job: InvoiceReminders::SendJob,
        args: [ normal_invoice.id, "overdue", 7, "firm" ]
      ) do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end

      clear_enqueued_jobs
      customer.update!(customer_segment: customer_segments(:bad_debtor_segment))
      bad_invoice = create_invoice(customer:, due_on: reminder_on + 3.days)

      assert_enqueued_jobs 1, only: InvoiceReminders::SendJob do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end
      assert_enqueued_with(
        job: InvoiceReminders::SendJob,
        args: [ bad_invoice.id, "pre_due", 3, "direct" ]
      )
    end
  end

  test "queues only outstanding invoices" do
    reminder_on = Date.new(2026, 11, 17)

    travel_to reminder_on.in_time_zone.change(hour: 12) do
      customer = create_customer(payer_segment: :normal_debtor)
      due_on = reminder_on + 7.days

      create_invoice(customer:, due_on:, status: :pending)
      create_invoice(customer:, due_on:, status: :paid, amount_due: 0)
      create_invoice(customer:, due_on:, status: :open, amount_due: 0)

      assert_no_enqueued_jobs only: InvoiceReminders::SendJob do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end
    end
  end

  test "does not queue a stage after either a sent or failed receipt" do
    reminder_on = Date.new(2026, 11, 17)

    travel_to reminder_on.in_time_zone.change(hour: 12) do
      good_customer = create_customer(payer_segment: :good_debtor)
      normal_customer = create_customer(payer_segment: :normal_debtor)
      good_stage = stage_for(:good_debtor, "pre_due_3")
      normal_stage = stage_for(:normal_debtor, "pre_due_7")

      sent_invoice = create_invoice(
        customer: good_customer,
        due_on: good_stage.invoice_due_on_for(reminder_on:)
      )
      failed_invoice = create_invoice(
        customer: normal_customer,
        due_on: normal_stage.invoice_due_on_for(reminder_on:)
      )

      create_receipt(invoice: sent_invoice, stage: good_stage, status: :sent)
      create_receipt(invoice: failed_invoice, stage: normal_stage, status: :failed)

      assert_no_enqueued_jobs only: InvoiceReminders::SendJob do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end
    end
  end

  test "a receipt for another stage does not block the due stage" do
    reminder_on = Date.new(2026, 11, 17)

    travel_to reminder_on.in_time_zone.change(hour: 12) do
      customer = create_customer(payer_segment: :good_debtor)
      due_stage = stage_for(:good_debtor, "pre_due_3")
      other_stage = stage_for(:good_debtor, "overdue_3")
      invoice = create_invoice(
        customer:,
        due_on: due_stage.invoice_due_on_for(reminder_on:)
      )
      create_receipt(invoice:, stage: other_stage, status: :sent)

      assert_enqueued_with(
        job: InvoiceReminders::SendJob,
        args: [ invoice.id, "pre_due", 3, "friendly" ]
      ) do
        Account::InvoiceReminders::ScheduleJob.perform_now
      end
    end
  end

  private
    def create_customer(payer_segment:, account: @account, invoice_source: @invoice_source)
      Customer.create!(
        account:,
        invoice_source:,
        customer_segment: account.customer_segment(payer_segment),
        external_id: "schedule-customer-#{SecureRandom.uuid}",
        name: "Schedule Customer",
        email: "schedule@example.com"
      )
    end

    def create_invoice(customer:, due_on:, status: :open, amount_due: 125)
      invoice = invoices(:xero_invoice).dup
      invoice.account = customer.account
      invoice.invoice_source = customer.invoice_source
      invoice.customer = customer
      invoice.external_id = "schedule-invoice-#{SecureRandom.uuid}"
      invoice.due_on = due_on
      invoice.status = status
      invoice.amount_due = amount_due
      invoice.paid_on = Date.current if status.to_sym == :paid
      invoice.save!
      invoice
    end

    def create_receipt(invoice:, stage:, status:)
      invoice.invoice_reminders.create!(
        account: invoice.account,
        category: stage.category,
        day_offset: stage.day_offset,
        stage_key: stage.key,
        status:,
        sent_at: status == :sent ? Time.current : nil
      )
    end

    def stage_for(payer_segment, stage_key)
      InvoiceReminder::Policy.stages_for(payer_segment:).find do |stage|
        stage.key == stage_key
      end
    end
end
