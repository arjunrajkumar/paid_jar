require "application_system_test_case"

class ConversationInboxTest < ApplicationSystemTestCase
  test "account user reviews, manually matches, and queues a threaded reply" do
    account = sign_up
    source_conversation, invoice = create_review_conversation(account)

    click_link "Inbox"

    assert_selector "h1", text: "Inbox"
    assert_selector ".app-nav-badge", text: "1"
    within ".app-conversation-row", text: "inbox-customer@example.com" do
      assert_text "Needs review"
      assert_text "Question about INV-SYSTEM-INBOX"
      click_link "inbox-customer@example.com"
    end

    assert_current_path conversation_path(
      source_conversation,
      script_name: account.slug
    )
    assert_text "Could you confirm when this invoice is due?"
    click_link "Match customer or invoice"
    select "Inbox Customer — INV-SYSTEM-INBOX", from: "Invoice"
    click_button "Match conversation"

    canonical = Conversation.for_invoice!(invoice:)
    assert_current_path conversation_path(
      canonical,
      script_name: account.slug
    )
    assert_text "Conversation matched."
    assert_text "Replying to inbox-customer@example.com"
    fill_in "Message", with: "The invoice is due next Friday."
    click_button "Send reply"

    assert_text "Reply queued."
    assert_text "The invoice is due next Friday."
    reply = canonical.conversation_messages.kind_manual_reply.sole
    assert_equal source_conversation.conversation_messages
      .kind_customer_email.sole,
      reply.reply_to_message
    assert_equal "system-inbox-thread", reply.requested_provider_thread_id
    assert_equal [ "<system-inbox-customer@example.com>" ],
      reply.in_reply_to_message_ids
    assert_equal [ "inbox-customer@example.com" ], reply.to_addresses

    click_button "Mark handled"

    assert_text "Conversation marked handled."
    assert_no_selector ".app-nav-badge"

    reply.mark_delivery_failed!(
      job_id: reply.delivery_job_id,
      failure_reason: "Gmail delivery failed."
    )
    ConversationMessages::ManualReplyOutcome.finalize!(reply)
    visit conversation_path(canonical, script_name: account.slug)

    assert_selector ".app-nav-badge", text: "1"
    click_button "Mark handled"
    assert_text "Conversation marked handled."
    assert_no_selector ".app-nav-badge"
  end

  private
    def sign_up
      visit new_signup_path
      fill_in "signup_email_address", with: "conversation-system@example.com"
      click_button "Let's go"
      assert_text "Check your email"
      fill_in "code", with: MagicLink.order(:created_at).last.code
      click_button "Continue"
      fill_in "signup_full_name", with: "Conversation User"
      click_button "Continue"
      assert_text "Welcome to PaymentReminder."

      Identity.find_by!(
        email_address: "conversation-system@example.com"
      ).accounts.first
    end

    def create_review_conversation(account)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "conversation-system-source"
      )
      customer = source.customers.create!(
        account:,
        external_id: "conversation-system-customer",
        name: "Inbox Customer",
        email: "inbox-customer@example.com"
      )
      invoice = source.invoices.create!(
        account:,
        customer:,
        external_id: "conversation-system-invoice",
        number: "INV-SYSTEM-INBOX",
        status: :open
      )
      account.update!(
        invoice_reminder_from_email: "billing-system-inbox@example.com"
      )
      connection = account.create_email_connection!(
        provider: :gmail,
        provider_account_id: "system-inbox-provider",
        connected_email: account.invoice_reminder_from_email,
        access_token: "system-inbox-access-token",
        refresh_token: "system-inbox-refresh-token",
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
        inbound_enabled_at: 1.hour.ago,
        last_inbound_synced_at: Time.current,
        status: :active
      )
      conversation = account.conversations.create!
      message = conversation.conversation_messages.create!(
        account:,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "system-inbox-provider-message",
        provider_thread_id: "system-inbox-thread",
        internet_message_id: "<system-inbox-customer@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        from_address: customer.email,
        subject: "Question about INV-SYSTEM-INBOX",
        body: "Could you confirm when this invoice is due?",
        matching_status: :unmatched,
        matching_method: :none,
        review_required: true,
        review_reasons: [ "invoice_unmatched" ]
      )
      conversation.update!(attention_required_at: message.received_at)
      [ conversation, invoice ]
    end
end
