require "test_helper"

class InvoiceReminderTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
  end

  test "belongs to an account invoice and invoice message" do
    reminder = build_reminder

    assert_equal @invoice.account, reminder.account
    assert_equal @invoice, reminder.invoice
    assert_equal @invoice, reminder.invoice_message.invoice
  end

  test "records a sent reminder receipt by default" do
    reminder = build_reminder

    assert reminder.save
    assert_predicate reminder, :category_pre_due?
    assert_predicate reminder, :status_sent?
  end

  test "records a failed reminder receipt" do
    reminder = build_reminder(
      invoice_message: build_message(status: :failed, sent_at: nil, failure_reason: "delivery failed")
    )

    assert reminder.save
    assert_predicate reminder, :status_failed?
    assert_equal "delivery failed", reminder.failure_reason
  end

  test "accepts every supported delivery tone" do
    InvoiceReminder::TONES.values.each do |tone|
      assert build_reminder(tone:).valid?, "Expected #{tone} to be valid"
    end
  end

  test "allows legacy receipts without a delivery tone" do
    assert build_reminder(tone: nil).valid?
  end

  test "allows legacy receipts without an invoice schedule" do
    assert build_reminder(invoice_schedule: nil).valid?
  end

  test "rejects an unsupported delivery tone" do
    reminder = build_reminder(tone: "urgent")

    assert_not reminder.valid?
    assert_includes reminder.errors[:tone], "is not included in the list"
  end

  test "requires a valid category and stage" do
    reminder = build_reminder(
      category: "other",
      stage_key: nil,
      day_offset: 0
    )

    assert_not reminder.valid?
    assert_includes reminder.errors[:category], "is not included in the list"
    assert_includes reminder.errors[:stage_key], "can't be blank"
    assert_includes reminder.errors[:day_offset], "must be greater than 0"
  end

  test "allows each stage only once per invoice" do
    build_reminder.save!
    duplicate = build_reminder

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:stage_key], "has already been taken"
  end

  test "requires the stage key to match its category and day offset" do
    reminder = build_reminder(stage_key: "overdue_3")

    assert_not reminder.valid?
    assert_includes reminder.errors[:stage_key], "must match category and day offset"
  end

  test "allows the same stage for another invoice" do
    build_reminder.save!
    other_invoice = @invoice.dup
    other_invoice.external_id = "invoice-reminder-other-invoice"
    other_invoice.save!

    assert build_reminder(invoice: other_invoice).valid?
  end

  test "requires its account to match its invoice account" do
    reminder = build_reminder(account: Account.create!(name: "Other Reminder Account"))

    assert_not reminder.valid?
    assert_includes reminder.errors[:account], "must match invoice account"
  end

  test "requires its message to match its invoice and account" do
    other_invoice = @invoice.dup
    other_invoice.external_id = "invoice-reminder-message-other-invoice"
    other_invoice.save!
    reminder = build_reminder(invoice_message: build_message(invoice: other_invoice))

    assert_not reminder.valid?
    assert_includes reminder.errors[:invoice_message], "must belong to the same invoice"
  end

  test "requires an outbound scheduled reminder message" do
    inbound_message = build_message(
      direction: :inbound,
      kind: :due_date_answer,
      status: :received,
      sent_at: nil,
      received_at: Time.current
    )
    reminder = build_reminder(invoice_message: inbound_message)

    assert_not reminder.valid?
    assert_includes reminder.errors[:invoice_message], "must be an outbound scheduled reminder"
  end

  test "allows an invoice message to describe only one reminder" do
    first = build_reminder
    first.save!
    duplicate = build_reminder(
      invoice_message: first.invoice_message,
      category: :overdue,
      day_offset: 3,
      stage_key: "overdue_3",
      invoice_schedule: nil
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:invoice_message_id], "has already been taken"
  end

  test "requires its invoice schedule to belong to the same account" do
    other_account = Account.create!(name: "Other Schedule Receipt Account")
    other_schedule = other_account.invoice_schedules.first
    reminder = build_reminder(invoice_schedule: other_schedule)

    assert_not reminder.valid?
    assert_includes reminder.errors[:invoice_schedule], "must belong to the same account"
  end

  test "allows one receipt per persisted schedule after its timing changes" do
    schedule = invoice_schedules(:normal_pre_due_7)
    build_reminder(invoice_schedule: schedule).save!
    schedule.update!(day_offset: 6)
    duplicate = build_reminder(
      invoice_schedule: schedule,
      stage_key: "pre_due_6",
      day_offset: 6
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:invoice_schedule_id], "has already been taken"
  end

  test "enforces stage uniqueness in the database" do
    build_reminder.save!

    assert_raises ActiveRecord::RecordNotUnique do
      build_reminder.save!(validate: false)
    end
  end

  test "fails a pending stage delivery only for its owning job" do
    reminder = build_reminder(
      invoice_message: build_message(
        status: :pending,
        sent_at: nil,
        delivery_job_id: "owner-job",
        delivery_attempted_at: Time.current
      )
    )
    reminder.save!

    assert_not InvoiceReminder.fail_owned_delivery_for_stage!(
      invoice: @invoice,
      stage_key: "pre_due_7",
      delivery_job_id: "other-job",
      failure_reason: "Should not win"
    )
    assert_predicate reminder.invoice_message.reload, :status_pending?

    assert InvoiceReminder.fail_owned_delivery_for_stage!(
      invoice: @invoice,
      stage_key: "pre_due_7",
      delivery_job_id: "owner-job",
      failure_reason: "Retries exhausted"
    )
    assert_predicate reminder.invoice_message.reload, :status_failed?
    assert_equal "Retries exhausted", reminder.failure_reason
  end

  private
    def build_reminder(attributes = {})
      invoice = attributes.fetch(:invoice, @invoice)
      account = attributes.fetch(:account, invoice.account)

      InvoiceReminder.new(
        {
          account:,
          invoice:,
          invoice_message: build_message(invoice:, account:),
          category: :pre_due,
          stage_key: "pre_due_7",
          day_offset: 7
        }.merge(attributes)
      )
    end

    def build_message(invoice: @invoice, account: invoice.account, **attributes)
      InvoiceMessage.new(
        {
          account:,
          invoice:,
          direction: :outbound,
          kind: :scheduled_reminder,
          status: :sent,
          sent_at: Time.current,
          to_addresses: [],
          cc_addresses: []
        }.merge(attributes)
      )
    end
end
