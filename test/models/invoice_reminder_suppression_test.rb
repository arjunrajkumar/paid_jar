require "test_helper"

class InvoiceReminderSuppressionTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @schedule = invoice_schedules(:normal_pre_due_7)
  end

  test "records why a scheduled stage was permanently skipped" do
    suppression = build_suppression

    assert suppression.save
    assert_predicate suppression, :reason_recent_outbound_message?
    assert_equal @invoice, suppression.invoice
    assert_equal @schedule, suppression.invoice_schedule
  end

  test "supports active payment promises as a suppression reason" do
    assert build_suppression(reason: :active_payment_promise).valid?
  end

  test "requires the account to match the invoice" do
    suppression = build_suppression(account: Account.create!(name: "Other Suppression Account"))

    assert_not suppression.valid?
    assert_includes suppression.errors[:account], "must match invoice account"
  end

  test "requires the schedule to belong to the same account" do
    other_account = Account.create!(name: "Other Suppression Schedule Account")
    suppression = build_suppression(invoice_schedule: other_account.invoice_schedules.first)

    assert_not suppression.valid?
    assert_includes suppression.errors[:invoice_schedule], "must belong to the same account"
  end

  test "requires the stage key to match its category and offset" do
    suppression = build_suppression(stage_key: "overdue_3")

    assert_not suppression.valid?
    assert_includes suppression.errors[:stage_key], "must match category and day offset"
  end

  test "allows each stage to be suppressed only once per invoice" do
    build_suppression.save!
    duplicate = build_suppression

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:stage_key], "has already been taken"
  end

  test "enforces one suppression for each invoice stage in the database" do
    build_suppression.save!

    assert_raises ActiveRecord::RecordNotUnique do
      build_suppression.save!(validate: false)
    end
  end

  private
    def build_suppression(attributes = {})
      InvoiceReminderSuppression.new(
        {
          account: @invoice.account,
          invoice: @invoice,
          invoice_schedule: @schedule,
          category: :pre_due,
          day_offset: 7,
          stage_key: "pre_due_7",
          reason: :recent_outbound_message,
          suppressed_at: Time.current
        }.merge(attributes)
      )
    end
end
