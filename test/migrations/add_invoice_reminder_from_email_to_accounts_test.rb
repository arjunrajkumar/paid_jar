require "test_helper"
require Rails.root.join("db/migrate/20260717123000_add_invoice_reminder_from_email_to_accounts")

class AddInvoiceReminderFromEmailToAccountsTest < ActiveSupport::TestCase
  test "backfills the sender from the active owner and preserves enabled reminders" do
    identity = Identity.create!(email_address: "legacy-owner@example.com")
    account = Account.create_with_owner(
      account: { name: "Legacy Owner Account" },
      owner: { name: "Legacy Owner", identity: }
    )
    account.update_columns(
      automatic_invoice_reminders_enabled: true,
      invoice_reminder_from_email: nil
    )

    run_backfill

    assert_equal "legacy-owner@example.com", account.reload.invoice_reminder_from_email
    assert_predicate account, :automatic_invoice_reminders_enabled?
  end

  test "disables existing reminders when no owner sender can be recovered" do
    account = Account.create!(name: "Legacy Account Without Owner")
    account.update_columns(
      automatic_invoice_reminders_enabled: true,
      invoice_reminder_from_email: nil
    )

    run_backfill

    assert_not_predicate account.reload, :automatic_invoice_reminders_enabled?
    assert_nil account.invoice_reminder_from_email
  end

  private
    def run_backfill
      AddInvoiceReminderFromEmailToAccounts.new.send(:backfill_existing_senders)
    end
end
