require "test_helper"
require "timeout"

class EmailMessageReceipts::ProcessorTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @connection = email_connections(:paid_jar_gmail)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
  end

  test "imports an archived customer reply into the existing Gmail thread" do
    sent_message = @conversation.conversation_messages.create!(
      account: @invoice.account,
      invoice: @invoice,
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: 1.day.ago,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "gmail-sent-1",
      provider_thread_id: "gmail-thread-1",
      internet_message_id: "<sent-1@example.com>",
      from_address: @connection.connected_email,
      to_addresses: [ @invoice.customer.email ],
      cc_addresses: [],
      subject: "Invoice INV-001",
      body: "Please pay."
    )
    @conversation.resolve!
    receipt = receipt_for("gmail-reply-1")
    receipt.claim!(job_id: "process-1")
    gmail_message = gmail_message(
      id: "gmail-reply-1",
      thread_id: sent_message.provider_thread_id,
      label_ids: [ "IMPORTANT" ],
      headers: {
        "From" => "Customer <customer@example.com>",
        "To" => @connection.connected_email,
        "Bcc" => "Archive <archive@example.com>",
        "Reply-To" => @invoice.customer.email,
        "Subject" => "Re: Invoice INV-001",
        "Message-ID" => "<reply-1@example.com>",
        "In-Reply-To" => sent_message.internet_message_id,
        "References" => "<older@example.com> #{sent_message.internet_message_id}"
      },
      body: "We have scheduled payment."
    )

    assert_difference -> { ConversationMessage.count }, 1 do
      assert_difference -> { ConversationEvent.kind_conversation_message_received.count }, 1 do
        EmailMessageReceipts::Processor.call(
          receipt,
          job_id: "process-1",
          mailbox: FakeMailbox.new(gmail_message)
        )
      end
    end

    imported = receipt.reload.conversation_message
    assert_predicate receipt, :status_processed?
    assert_equal @conversation, imported.conversation
    assert_equal @invoice, imported.invoice
    assert_predicate imported, :direction_inbound?
    assert_predicate imported, :kind_customer_email?
    assert_predicate imported, :status_received?
    assert_equal [ "archive@example.com" ], imported.bcc_addresses
    assert_equal @invoice.customer.email, imported.reply_to_addresses.sole
    assert_equal @connection.credential_generation, imported.email_connection_generation
    assert_equal "<reply-1@example.com>", imported.internet_message_id
    assert_equal [ sent_message.internet_message_id ], imported.in_reply_to_message_ids
    assert_equal "We have scheduled payment.", imported.body
    assert_in_delta Time.current, imported.received_at, 1.second
    assert_not imported.review_required?
    assert_predicate @conversation.reload, :status_open?
  end

  test "imports a manually sent Gmail message and counts it for the cooldown" do
    @conversation.resolve!
    receipt = receipt_for("gmail-manual-1")
    receipt.claim!(job_id: "process-manual")
    gmail_message = gmail_message(
      id: "gmail-manual-1",
      thread_id: "gmail-manual-thread",
      label_ids: [ "SENT" ],
      headers: {
        "From" => @connection.connected_email,
        "Bcc" => @invoice.customer.email,
        "Subject" => "Invoice INV-001",
        "Message-ID" => "<manual-1@example.com>"
      },
      body: "A reminder sent directly from Gmail."
    )

    EmailMessageReceipts::Processor.call(
      receipt,
      job_id: "process-manual",
      mailbox: FakeMailbox.new(gmail_message)
    )

    imported = receipt.reload.conversation_message
    assert_predicate imported, :kind_manual_email?
    assert_predicate imported, :direction_outbound?
    assert_predicate imported, :status_sent?
    assert_equal @conversation, imported.conversation
    assert_equal [ @invoice.customer.email ], imported.bcc_addresses
    assert_predicate @conversation.reload, :status_resolved?
    assert_includes @invoice.conversation_messages.successful_outbound.sent_after(2.days.ago), imported
  end

  test "review-required imported outbound mail creates shared Inbox attention" do
    receipt = receipt_for("gmail-outbound-review")
    receipt.claim!(job_id: "process-outbound-review")
    gmail_message = gmail_message(
      id: "gmail-outbound-review",
      thread_id: "gmail-outbound-review-thread",
      label_ids: [ "SENT" ],
      headers: {
        "From" => @connection.connected_email,
        "To" => @invoice.customer.email,
        "Subject" => "A note without an invoice reference",
        "Message-ID" => "<gmail-outbound-review@example.com>"
      },
      body: "Please review this manually sent note."
    )

    EmailMessageReceipts::Processor.call(
      receipt,
      job_id: "process-outbound-review",
      mailbox: FakeMailbox.new(gmail_message)
    )

    imported = receipt.reload.conversation_message
    assert_predicate imported, :direction_outbound?
    assert_predicate imported, :awaiting_review?
    assert_equal imported.occurred_at,
      imported.conversation.reload.attention_required_at
    assert_includes Conversations::Inbox.call(
      account: @invoice.account,
      filter: :needs_attention
    ), imported.conversation
  end

  test "links an existing app-sent message without importing it again" do
    existing = @conversation.conversation_messages.create!(
      account: @invoice.account,
      invoice: @invoice,
      direction: :outbound,
      kind: :manual_reminder,
      status: :sent,
      sent_at: Time.current,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "gmail-existing",
      provider_thread_id: "gmail-existing-thread",
      from_address: @connection.connected_email,
      to_addresses: [ @invoice.customer.email ],
      cc_addresses: [],
      subject: "Invoice INV-001",
      body: "Existing message"
    )
    receipt = receipt_for("gmail-existing")
    receipt.claim!(job_id: "process-existing")
    assert_no_difference -> { ConversationMessage.count } do
      EmailMessageReceipts::Processor.call(
        receipt,
        job_id: "process-existing",
        mailbox: ExplodingMailbox.new
      )
    end

    assert_equal existing, receipt.reload.conversation_message
    assert_predicate receipt, :status_processed?
  end

  test "links an existing app-sent message after same-mailbox reauthorization" do
    existing = @conversation.conversation_messages.create!(
      account: @invoice.account,
      invoice: @invoice,
      direction: :outbound,
      kind: :manual_reminder,
      status: :sent,
      sent_at: Time.current,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "gmail-existing-before-reauthorization",
      provider_thread_id: "gmail-existing-thread",
      from_address: @connection.connected_email,
      to_addresses: [ @invoice.customer.email ],
      cc_addresses: [],
      subject: "Invoice INV-001",
      body: "Existing message"
    )
    @connection.increment!(:credential_generation)
    receipt = receipt_for("gmail-existing-before-reauthorization")
    receipt.claim!(job_id: "process-existing-after-reauthorization")

    assert_no_difference -> { ConversationMessage.count } do
      EmailMessageReceipts::Processor.call(
        receipt,
        job_id: "process-existing-after-reauthorization",
        mailbox: ExplodingMailbox.new
      )
    end

    assert_equal existing, receipt.reload.conversation_message
    assert_predicate receipt, :status_processed?
    assert_not_equal existing.email_connection_generation, receipt.email_connection_generation
  end

  test "ignores unrelated, draft, and trash messages without copying content" do
    {
      "unrelated" => [ "STARRED" ],
      "draft" => [ "DRAFT" ],
      "trash" => [ "TRASH" ]
    }.each do |id, labels|
      receipt = receipt_for("gmail-#{id}")
      receipt.claim!(job_id: "process-#{id}")
      message = gmail_message(
        id: "gmail-#{id}",
        thread_id: "thread-#{id}",
        label_ids: labels,
        headers: {
          "From" => "stranger@example.net",
          "To" => @connection.connected_email,
          "Subject" => "Private mailbox message"
        },
        body: "This unrelated body must not become a ConversationMessage."
      )

      assert_no_difference -> { ConversationMessage.count } do
        EmailMessageReceipts::Processor.call(
          receipt,
          job_id: "process-#{id}",
          mailbox: FakeMailbox.new(message)
        )
      end
      assert_predicate receipt.reload, :status_ignored?
    end
  end

  test "durably reconsiders an earlier unrelated message when its thread gains a customer anchor" do
    unknown_receipt = receipt_for("unknown-before-anchor")
    unknown_receipt.claim!(job_id: "process-unknown-before-anchor")
    EmailMessageReceipts::Processor.call(
      unknown_receipt,
      job_id: "process-unknown-before-anchor",
      mailbox: FakeMailbox.new(
        gmail_message(
          id: "unknown-before-anchor",
          thread_id: "late-anchor-thread",
          label_ids: [ "INBOX" ],
          headers: {
            "From" => "unknown@example.net",
            "To" => @connection.connected_email,
            "Subject" => "A question"
          },
          body: "Please help"
        )
      )
    )
    assert_predicate unknown_receipt.reload, :status_ignored?

    old_generation = unknown_receipt.email_connection_generation
    @connection.connect_gmail!(
      email: @connection.connected_email,
      name: @connection.provider_display_name,
      provider_account_id: @connection.provider_account_id,
      history_id: @connection.inbound_cursor,
      access_token: "reauthorized-access-token",
      refresh_token: "reauthorized-refresh-token",
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )
    anchor = import_customer_message(
      id: "known-thread-anchor",
      thread_id: "late-anchor-thread"
    )

    assert anchor
    assert_predicate unknown_receipt.reload, :status_pending?
    assert_not_equal old_generation, unknown_receipt.email_connection_generation
    assert_equal @connection.credential_generation, unknown_receipt.email_connection_generation
    assert_empty unknown_receipt.metadata
  end

  test "ignores a malformed unrelated message without creating a conversation" do
    receipt = receipt_for("gmail-malformed-unrelated")
    receipt.claim!(job_id: "process-malformed")
    malformed = Google::Apis::GmailV1::Message.new(
      id: "gmail-malformed-unrelated",
      thread_id: "malformed-unrelated-thread",
      internal_date: (Time.current.to_f * 1000).to_i.to_s,
      label_ids: [ "INBOX" ],
      payload: nil
    )

    assert_no_difference [ -> { Conversation.count }, -> { ConversationMessage.count } ] do
      EmailMessageReceipts::Processor.call(
        receipt,
        job_id: "process-malformed",
        mailbox: FakeMailbox.new(malformed)
      )
    end

    assert_predicate receipt.reload, :status_ignored?
    assert_equal "unrelated", receipt.metadata.fetch("reason")
  end

  test "does not link a provider ID from a replaced mailbox identity" do
    current_identity = @connection.provider_account_id
    @connection.update_column(:provider_account_id, "old-google-account")
    existing = @conversation.conversation_messages.create!(
      account: @invoice.account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: "old-google-account",
      direction: :outbound,
      kind: :manual_reminder,
      status: :sent,
      sent_at: Time.current,
      provider_message_id: "identity-collision",
      provider_thread_id: "old-thread",
      from_address: @connection.connected_email,
      to_addresses: [ @invoice.customer.email ],
      cc_addresses: [],
      subject: "Invoice INV-001",
      body: "Old mailbox message"
    )
    @connection.update_column(:provider_account_id, current_identity)
    receipt = receipt_for("identity-collision")
    receipt.claim!(job_id: "process-replacement")
    replacement_message = gmail_message(
      id: "identity-collision",
      thread_id: "replacement-thread",
      label_ids: [ "SENT" ],
      headers: {
        "From" => @connection.connected_email,
        "To" => @invoice.customer.email,
        "Subject" => "Invoice INV-001"
      },
      body: "Replacement mailbox message"
    )

    EmailMessageReceipts::Processor.call(
      receipt,
      job_id: "process-replacement",
      mailbox: FakeMailbox.new(replacement_message)
    )

    assert_not_equal existing, receipt.reload.conversation_message
    assert_equal @connection.provider_account_id, receipt.conversation_message.provider_account_id
  end

  test "a worker that lost its claim cannot record, link, update the thread, or reopen" do
    @conversation.resolve!
    receipt = receipt_for("lost-claim")
    receipt.claim!(job_id: "worker-a", at: 1.hour.ago)
    receipt.recover_stale_processing!(before: 30.minutes.ago)
    receipt.claim!(job_id: "worker-b")
    message = gmail_message(
      id: "lost-claim",
      thread_id: "lost-claim-thread",
      label_ids: [ "INBOX" ],
      headers: {
        "From" => @invoice.customer.email,
        "To" => @connection.connected_email,
        "Subject" => "Invoice INV-001"
      },
      body: "Payment is scheduled."
    )
    parsed_message = EmailConnection::Gmail::MessageParser.call(message)
    match = ConversationMessages::EmailMatcher.call(
      account: @invoice.account,
      provider_account_id: receipt.provider_account_id,
      parsed_message:,
      direction: :inbound
    )

    assert_no_difference [
      -> { Conversation.count },
      -> { ConversationMessage.count },
      -> { ConversationEvent.count }
    ] do
      assert_raises EmailMessageReceipt::ClaimLost do
        ConversationMessages::EmailRecorder.call(
          account: @invoice.account,
          receipt:,
          parsed_message:,
          direction: :inbound,
          match:,
          job_id: "worker-a",
          provider_account_id: receipt.provider_account_id
        )
      end
    end

    assert_predicate receipt.reload, :status_processing?
    assert_equal "worker-b", receipt.processing_job_id
    assert_nil receipt.provider_thread_id
    assert_predicate @conversation.reload, :status_resolved?

    EmailMessageReceipts::Processor.call(
      receipt,
      job_id: "worker-b",
      mailbox: FakeMailbox.new(message)
    )
    assert_predicate receipt.reload, :status_processed?
    assert_equal "lost-claim-thread", receipt.provider_thread_id
    assert_predicate @conversation.reload, :status_open?
  end

  test "a credential change between matching and recording cannot write mailbox data" do
    receipt = receipt_for("generation-changed-before-record")
    receipt.claim!(job_id: "old-generation-worker")
    message = gmail_message(
      id: receipt.provider_message_id,
      thread_id: "generation-changed-thread",
      label_ids: [ "INBOX" ],
      headers: {
        "From" => @invoice.customer.email,
        "To" => @connection.connected_email,
        "Subject" => "Question about #{@invoice.number}"
      },
      body: "Please confirm the balance."
    )
    parsed_message = EmailConnection::Gmail::MessageParser.call(message)
    match = ConversationMessages::EmailMatcher.call(
      account: @invoice.account,
      provider_account_id: receipt.provider_account_id,
      parsed_message:,
      direction: :inbound
    )
    @connection.increment!(:credential_generation)

    assert_no_difference [
      -> { Conversation.count },
      -> { ConversationMessage.count },
      -> { ConversationEvent.count }
    ] do
      assert_raises EmailConnection::Errors::CredentialChanged do
        ConversationMessages::EmailRecorder.call(
          account: @invoice.account,
          receipt:,
          parsed_message:,
          direction: :inbound,
          match:,
          job_id: "old-generation-worker",
          provider_account_id: receipt.provider_account_id
        )
      end
    end

    assert_predicate receipt.reload, :status_processing?
    assert_nil receipt.conversation_message
  end

  test "independent Gmail threads from one known customer create independent conversations" do
    first = import_customer_message(id: "customer-thread-one", thread_id: "thread-one")
    second = import_customer_message(id: "customer-thread-two", thread_id: "thread-two")
    first_follow_up = import_customer_message(id: "customer-thread-one-reply", thread_id: "thread-one")
    second_follow_up = import_customer_message(id: "customer-thread-two-reply", thread_id: "thread-two")

    assert_not_equal first.conversation, second.conversation
    assert_equal first.conversation, first_follow_up.conversation
    assert_equal second.conversation, second_follow_up.conversation
    assert_nil first.invoice
    assert_nil second.invoice
  end

  test "independent Gmail threads for the same exact invoice reuse its canonical conversation" do
    first = import_customer_message(
      id: "invoice-thread-one",
      thread_id: "invoice-thread-one",
      subject: "Question about INV-001"
    )
    second = import_customer_message(
      id: "invoice-thread-two",
      thread_id: "invoice-thread-two",
      subject: "Another question about INV-001"
    )

    assert_equal @conversation, first.conversation
    assert_equal @conversation, second.conversation
  end

  test "a known customer enriches an account-only strong thread and records the assignment" do
    account_only = @invoice.account.conversations.create!
    account_only.conversation_messages.create!(
      account: @invoice.account,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.day.ago,
      provider_message_id: "account-only-seed",
      provider_thread_id: "account-only-thread",
      from_address: "unknown@example.net",
      to_addresses: [ @connection.connected_email ],
      cc_addresses: [],
      subject: "General question",
      body: "Hello"
    )

    imported = import_customer_message(
      id: "account-only-known",
      thread_id: "account-only-thread",
      subject: "A follow-up"
    )

    assert_equal account_only, imported.conversation
    assert_equal @invoice.customer, account_only.reload.customer
    event = imported.conversation_events.find_by!(kind: :conversation_message_received)
    assert_equal true, event.metadata.fetch("conversation_customer_assigned")

    other_customer = @invoice.account.customers.create!(
      invoice_source: invoice_sources(:xero),
      customer_segment: customer_segments(:normal_debtor_segment),
      external_id: "processor-conflicting-customer",
      name: "Conflicting customer",
      email: "conflicting-customer@example.com"
    )
    conflict = import_customer_message(
      id: "account-only-conflict",
      thread_id: "account-only-thread",
      subject: "A conflicting follow-up",
      from_address: other_customer.email
    )

    assert_predicate conflict, :matching_status_ambiguous?
    assert_includes conflict.review_reasons, "address_conflicts_with_thread"
    assert_not_equal account_only, conflict.conversation
    assert_equal @invoice.customer, account_only.reload.customer
  end

  test "a conflicting invoice reference does not reopen or attach to the strong thread" do
    other_invoice = @invoice.dup
    other_invoice.external_id = "processor-other-invoice"
    other_invoice.number = "PROC-OTHER"
    other_invoice.save!
    seed = @conversation.conversation_messages.create!(
      account: @invoice.account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      direction: :outbound,
      kind: :manual_reminder,
      status: :sent,
      sent_at: 1.day.ago,
      provider_message_id: "conflict-seed",
      provider_thread_id: "conflict-thread",
      from_address: @connection.connected_email,
      to_addresses: [ @invoice.customer.email ],
      cc_addresses: [],
      subject: "Invoice #{@invoice.number}",
      body: "Please pay"
    )
    assert seed
    @conversation.resolve!

    imported = import_customer_message(
      id: "conflicting-invoice",
      thread_id: "conflict-thread",
      subject: "Question about #{other_invoice.number}"
    )

    assert_not_equal @conversation, imported.conversation
    assert_nil imported.invoice
    assert_predicate imported, :matching_status_ambiguous?
    assert_includes imported.review_reasons, "invoice_thread_conflict"
    assert_predicate @conversation.reload, :status_resolved?
  end

  test "manual matching and message matching serialize without stranding a receipt" do
    source = @invoice.account.conversations.create!
    reviewed = source.conversation_messages.create!(
      account: @invoice.account,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "manual-match-race-anchor",
      provider_thread_id: "manual-match-race-thread",
      internet_message_id: "<manual-match-race-anchor@example.com>",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.hour.ago,
      from_address: "unknown-anchor@example.net",
      matching_status: :ambiguous,
      matching_method: :none,
      review_required: true,
      review_reasons: [ "invoice_thread_conflict" ]
    )
    receipt = receipt_for("manual-match-race-follow-up")
    receipt.claim!(job_id: "manual-match-race-job")
    message = gmail_message(
      id: "manual-match-race-follow-up",
      thread_id: "manual-match-race-thread",
      label_ids: [ "IMPORTANT" ],
      headers: {
        "From" => "Unknown <unknown-follow-up@example.net>",
        "To" => @connection.connected_email,
        "Subject" => "A follow-up",
        "Message-ID" => "<manual-match-race-follow-up@example.net>"
      },
      body: "Following up."
    )
    match_calculated = Queue.new
    continue_processing = Queue.new
    manual_finished = Queue.new
    thread_errors = Queue.new
    matcher_singleton = ConversationMessages::EmailMatcher.singleton_class
    original_matcher = matcher_singleton.instance_method(:call)
    pausing_matcher = lambda do |**arguments|
      result = original_matcher.bind_call(
        ConversationMessages::EmailMatcher,
        **arguments
      )
      match_calculated << true
      continue_processing.pop
      result
    end

    matcher_singleton.define_method(:call, &pausing_matcher)
    begin
      processor = Thread.new do
        EmailMessageReceipts::Processor.call(
          receipt,
          job_id: "manual-match-race-job",
          mailbox: FakeMailbox.new(message)
        )
      rescue StandardError => error
        thread_errors << error
      end
      Timeout.timeout(2) { match_calculated.pop }
      matcher = Thread.new do
        Conversations::ManualMatcher.call(
          source_conversation: source,
          reviewed_message: reviewed,
          target_invoice: @invoice,
          actor_user: users(:arjun),
          work_unit_token: conversation_work_unit_token(source)
        )
        manual_finished << true
      rescue StandardError => error
        thread_errors << error
      end
      begin
        Timeout.timeout(0.25) { manual_finished.pop }
      rescue Timeout::Error
        nil
      end
      continue_processing << true
      processor.join
      matcher.join
    ensure
      matcher_singleton.define_method(:call, original_matcher)
    end

    raise thread_errors.pop unless thread_errors.empty?
    assert_equal Conversation.for_invoice!(invoice: @invoice),
      source.reload.canonical_conversation
    assert_predicate receipt.reload, :status_pending?
  ensure
    continue_processing << true if continue_processing
  end

  private
    def receipt_for(provider_message_id)
      @connection.email_message_receipts.create!(
        account: @invoice.account,
        provider_message_id:,
        discovered_at: Time.current
      )
    end

    def import_customer_message(
      id:,
      thread_id:,
      subject: "A general question",
      from_address: @invoice.customer.email
    )
      receipt = receipt_for(id)
      receipt.claim!(job_id: "process-#{id}")
      EmailMessageReceipts::Processor.call(
        receipt,
        job_id: "process-#{id}",
        mailbox: FakeMailbox.new(
          gmail_message(
            id:,
            thread_id:,
            label_ids: [ "INBOX" ],
            headers: {
              "From" => from_address,
              "To" => @connection.connected_email,
              "Subject" => subject,
              "Message-ID" => "<#{id}@example.com>"
            },
            body: "Hello"
          )
        )
      )
      receipt.reload.conversation_message
    end

    def gmail_message(id:, thread_id:, label_ids:, headers:, body:)
      Google::Apis::GmailV1::Message.new(
        id:,
        thread_id:,
        internal_date: (Time.current.to_f * 1000).to_i.to_s,
        label_ids:,
        payload: Google::Apis::GmailV1::MessagePart.new(
          mime_type: "multipart/alternative",
          headers: headers.map do |name, value|
            Google::Apis::GmailV1::MessagePartHeader.new(name:, value:)
          end,
          parts: [
            Google::Apis::GmailV1::MessagePart.new(
              mime_type: "text/html",
              body: Google::Apis::GmailV1::MessagePartBody.new(
                data: "<p>HTML fallback</p>"
              )
            ),
            Google::Apis::GmailV1::MessagePart.new(
              mime_type: "text/plain",
              body: Google::Apis::GmailV1::MessagePartBody.new(
                data: body
              )
            )
          ]
        )
      )
    end

    class FakeMailbox
      def initialize(message)
        @message = message
      end

      def message(id:)
        raise "unexpected message" unless id == @message.id

        @message
      end
    end


    class ExplodingMailbox
      def message(id:)
        raise "mailbox should not be fetched for locally linked message #{id}"
      end
    end
end
