require "test_helper"

class PlatformAdminEventTest < ActiveSupport::TestCase
  test "snapshots the actor and infers the target account" do
    actor = Identity.create!(email_address: "audit-actor@example.com")
    invoice = invoices(:xero_invoice)

    event = PlatformAdminEvent.record!(
      actor:,
      action: "invoices.send_manual_reminder",
      target: invoice,
      metadata: { changed_fields: [] }
    )

    assert_equal actor, event.actor_identity
    assert_equal "audit-actor@example.com", event.actor_email_address
    assert_equal invoice, event.target
    assert_equal invoice.account, event.account
  end

  test "retains actor email when the identity is removed" do
    actor = Identity.create!(email_address: "former-admin@example.com")
    event = PlatformAdminEvent.record!(actor:, action: "accounts.update")

    actor.destroy!

    assert_nil event.reload.actor_identity
    assert_equal "former-admin@example.com", event.actor_email_address
  end
end
