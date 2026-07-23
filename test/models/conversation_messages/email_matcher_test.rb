require "test_helper"

class ConversationMessages::EmailMatcherTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @provider_account_id = email_connections(:paid_jar_gmail).provider_account_id
    @customer = customers(:xero_customer)
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @sent_message = @conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: 1.day.ago,
      provider_account_id: @provider_account_id,
      provider_message_id: "matcher-sent",
      provider_thread_id: "matcher-thread",
      internet_message_id: "<matcher-sent@example.com>",
      from_address: "billing@paymentreminder.example",
      to_addresses: [ @customer.email ],
      cc_addresses: [],
      subject: "Invoice INV-001",
      body: "Please pay."
    )
  end

  test "matches a known sender and exact invoice token" do
    result = match_email(parsed_message(from_address: @customer.email, subject: "Question about INV-001"))

    assert result.relevant?
    assert_equal @invoice, result.invoice
    assert_equal @customer, result.customer
    assert_equal "matched", result.matching_status
    assert_equal "invoice_reference", result.matching_method
  end

  test "does not infer an invoice from a customer address alone" do
    result = match_email(parsed_message(from_address: @customer.email, subject: "A general question"))

    assert result.relevant?
    assert_nil result.invoice
    assert_equal @customer, result.customer
    assert_equal "unmatched", result.matching_status
    assert_equal "customer_only", result.matching_method
    assert result.review_required
  end

  test "marks Gmail and RFC thread disagreement ambiguous" do
    other_invoice = @invoice.dup
    other_invoice.external_id = "matcher-other-invoice"
    other_invoice.number = "MATCHER-2"
    other_invoice.save!
    other_conversation = Conversation.for_invoice!(invoice: other_invoice)
    other_conversation.conversation_messages.create!(
      account: @account,
      invoice: other_invoice,
      direction: :outbound,
      kind: :manual_reminder,
      status: :sent,
      sent_at: Time.current,
      provider_account_id: @provider_account_id,
      internet_message_id: "<other-thread@example.com>",
      from_address: "billing@paymentreminder.example",
      to_addresses: [ @customer.email ],
      cc_addresses: [],
      subject: "Other",
      body: "Other"
    )

    result = match_email(parsed_message(
      provider_thread_id: @sent_message.provider_thread_id,
      from_address: @customer.email,
      in_reply_to_message_ids: [ "<other-thread@example.com>" ]
    ))

    assert_equal "ambiguous", result.matching_status
    assert_nil result.conversation
    assert_includes result.review_reasons, "gmail_rfc_thread_conflict"
  end

  test "attaches an unknown participant to a coherent thread with review" do
    result = match_email(parsed_message(
      provider_thread_id: @sent_message.provider_thread_id,
      from_address: "new-participant@example.net"
    ))

    assert_equal @conversation, result.conversation
    assert_equal "matched", result.matching_status
    assert result.review_required
    assert_includes result.review_reasons, "unknown_sender"
  end

  test "keeps a thread match when its sole invoice reference agrees" do
    result = match_email(parsed_message(
      provider_thread_id: @sent_message.provider_thread_id,
      from_address: @customer.email,
      subject: "Question about INV-001"
    ))

    assert_equal @conversation, result.conversation
    assert_equal @invoice, result.invoice
    assert_equal "matched", result.matching_status
    assert_equal "gmail_thread", result.matching_method
  end

  test "marks a thread and different invoice reference ambiguous" do
    create_other_invoice(number: "MATCHER-2")

    result = match_email(parsed_message(
      provider_thread_id: @sent_message.provider_thread_id,
      from_address: @customer.email,
      subject: "Question about MATCHER-2"
    ))

    assert_equal "ambiguous", result.matching_status
    assert_nil result.conversation
    assert_nil result.invoice
    assert result.review_required
    assert_includes result.review_reasons, "invoice_thread_conflict"
  end

  test "marks a thread with multiple distinct invoice references ambiguous" do
    create_other_invoice(number: "MATCHER-2")

    result = match_email(parsed_message(
      provider_thread_id: @sent_message.provider_thread_id,
      from_address: @customer.email,
      subject: "Question about INV-001 and MATCHER-2"
    ))

    assert_equal "ambiguous", result.matching_status
    assert_nil result.conversation
    assert_includes result.review_reasons, "multiple_invoice_references"
  end

  test "marks an RFC match and different invoice reference ambiguous" do
    create_other_invoice(number: "MATCHER-2")

    result = match_email(parsed_message(
      from_address: @customer.email,
      subject: "Question about MATCHER-2",
      in_reply_to_message_ids: [ @sent_message.internet_message_id ]
    ))

    assert_equal "ambiguous", result.matching_status
    assert_nil result.conversation
    assert_includes result.review_reasons, "invoice_thread_conflict"
  end

  test "does not reuse an invoice-less conversation based only on customer" do
    existing = @account.conversations.create!(customer: @customer)

    result = match_email(parsed_message(
      provider_thread_id: "new-unrelated-thread",
      from_address: @customer.email,
      subject: "A separate general question"
    ))

    assert_nil result.conversation
    assert_equal @customer, result.customer
    assert_equal "unmatched", result.matching_status
    assert_equal "customer_only", result.matching_method
    assert_predicate existing, :persisted?
  end

  test "reuses each invoice-less conversation only for its Gmail thread" do
    first_conversation = create_unmatched_thread("unmatched-thread-1")
    second_conversation = create_unmatched_thread("unmatched-thread-2")

    first_result = match_email(parsed_message(
      provider_thread_id: "unmatched-thread-1",
      from_address: @customer.email
    ))
    second_result = match_email(parsed_message(
      provider_thread_id: "unmatched-thread-2",
      from_address: @customer.email
    ))

    assert_equal first_conversation, first_result.conversation
    assert_equal second_conversation, second_result.conversation
  end

  test "requires review for an unknown CC on otherwise matched outbound email" do
    result = match_email(parsed_message(
      from_address: "billing@paymentreminder.example",
      to_addresses: [ @customer.email ],
      cc_addresses: [ "outside-collaborator@example.net" ],
      subject: "Invoice INV-001"
    ), direction: :outbound)

    assert_equal @invoice, result.invoice
    assert_equal @customer, result.customer
    assert_equal "matched", result.matching_status
    assert result.review_required
    assert_includes result.review_reasons, "unknown_recipient"
  end

  test "matches a customer copied only by BCC on outbound email" do
    result = match_email(parsed_message(
      from_address: "billing@paymentreminder.example",
      to_addresses: [],
      cc_addresses: [],
      bcc_addresses: [ @customer.email ],
      subject: "Invoice INV-001"
    ), direction: :outbound)

    assert_equal @invoice, result.invoice
    assert_equal @customer, result.customer
    assert_equal "matched", result.matching_status
    assert_not result.review_required
  end

  test "requires review for an unknown BCC on otherwise matched outbound email" do
    result = match_email(parsed_message(
      from_address: "billing@paymentreminder.example",
      to_addresses: [ @customer.email ],
      cc_addresses: [],
      bcc_addresses: [ "outside-collaborator@example.net" ],
      subject: "Invoice INV-001"
    ), direction: :outbound)

    assert_equal @invoice, result.invoice
    assert_equal @customer, result.customer
    assert_equal "matched", result.matching_status
    assert result.review_required
    assert_includes result.review_reasons, "unknown_recipient"
  end

  test "allows an inbound Reply-To belonging to the matched customer" do
    result = match_email(parsed_message(
      from_address: @customer.email,
      reply_to_addresses: [ @customer.email ],
      subject: "Question about INV-001"
    ))

    assert_equal @customer, result.customer
    assert_equal "matched", result.matching_status
    assert_not result.review_required
  end

  test "requires review for an unknown inbound Reply-To" do
    result = match_email(parsed_message(
      from_address: @customer.email,
      reply_to_addresses: [ "unverified-replies@example.net" ],
      subject: "Question about INV-001"
    ))

    assert_equal @customer, result.customer
    assert_equal "matched", result.matching_status
    assert result.review_required
    assert_includes result.review_reasons, "unknown_reply_to"
  end

  test "marks an inbound Reply-To belonging to another customer ambiguous" do
    other_customer = @account.customers.create!(
      invoice_source: invoice_sources(:xero),
      customer_segment: customer_segments(:normal_debtor_segment),
      external_id: "matcher-reply-to-other-customer",
      name: "Reply-To customer",
      email: "reply-to-customer@example.net"
    )

    result = match_email(parsed_message(
      from_address: @customer.email,
      reply_to_addresses: [ other_customer.email ],
      subject: "Question about INV-001"
    ))

    assert_equal "ambiguous", result.matching_status
    assert_nil result.conversation
    assert_includes result.review_reasons, "reply_to_customer_conflict"
  end

  test "does not use Reply-To as positive customer identity" do
    result = match_email(parsed_message(
      from_address: "unknown-sender@example.net",
      reply_to_addresses: [ @customer.email ],
      subject: "A general question"
    ))

    assert_not result.relevant?
    assert_nil result.customer
    assert_nil result.conversation
  end

  test "requires review for an unknown To address with a known customer CC" do
    result = match_email(parsed_message(
      from_address: "billing@paymentreminder.example",
      to_addresses: [ "outside-collaborator@example.net" ],
      cc_addresses: [ @customer.email ],
      subject: "Invoice INV-001"
    ), direction: :outbound)

    assert_equal @invoice, result.invoice
    assert_equal @customer, result.customer
    assert_equal "matched", result.matching_status
    assert result.review_required
    assert_includes result.review_reasons, "unknown_recipient"
  end

  test "keeps a known-customer-only outbound match clean" do
    result = match_email(parsed_message(
      from_address: "billing@paymentreminder.example",
      to_addresses: [ @customer.email ],
      cc_addresses: [],
      subject: "Invoice INV-001"
    ), direction: :outbound)

    assert_equal @invoice, result.invoice
    assert_equal "matched", result.matching_status
    assert_not result.review_required
    assert_not_includes result.review_reasons, "unknown_recipient"
  end

  test "marks outbound recipients belonging to different customers ambiguous" do
    other_customer = @account.customers.create!(
      invoice_source: invoice_sources(:xero),
      customer_segment: customer_segments(:normal_debtor_segment),
      external_id: "matcher-outbound-other-customer",
      name: "Other outbound customer",
      email: "other-customer@example.net"
    )

    result = match_email(parsed_message(
      from_address: "billing@paymentreminder.example",
      to_addresses: [ @customer.email, other_customer.email ],
      cc_addresses: [],
      subject: "General account question"
    ), direction: :outbound)

    assert_equal "ambiguous", result.matching_status
    assert_nil result.conversation
    assert_includes result.review_reasons, "multiple_customer_recipients"
  end

  test "treats one outbound address shared by customers as a duplicate address" do
    other_customer = @account.customers.create!(
      invoice_source: invoice_sources(:xero),
      customer_segment: customer_segments(:normal_debtor_segment),
      external_id: "matcher-outbound-shared-customer",
      name: "Other shared-address customer",
      email: @customer.email
    )
    assert_predicate other_customer, :persisted?

    result = match_email(parsed_message(
      from_address: "billing@paymentreminder.example",
      to_addresses: [ @customer.email ],
      cc_addresses: [],
      subject: "General account question"
    ), direction: :outbound)

    assert_equal "ambiguous", result.matching_status
    assert_includes result.review_reasons, "duplicate_customer_address"
    assert_not_includes result.review_reasons, "multiple_customer_recipients"
  end

  test "keeps a missing-payload message relevant on a known Gmail thread" do
    parsed = EmailConnection::Gmail::MessageParser.call(
      Google::Apis::GmailV1::Message.new(
        id: "matcher-malformed-known",
        thread_id: @sent_message.provider_thread_id,
        internal_date: "1721648000000",
        label_ids: [ "INBOX" ]
      )
    )

    result = match_email(parsed)

    assert_equal @conversation, result.conversation
    assert_equal "matched", result.matching_status
    assert result.review_required
    assert_includes result.review_reasons, "parse_error"
  end

  test "does not treat a missing-payload unrelated message as relevant" do
    parsed = EmailConnection::Gmail::MessageParser.call(
      Google::Apis::GmailV1::Message.new(
        id: "matcher-malformed-unrelated",
        thread_id: "matcher-malformed-unrelated-thread",
        internal_date: "1721648000000",
        label_ids: [ "INBOX" ]
      )
    )

    assert_no_difference -> { Conversation.count } do
      result = match_email(parsed)

      assert_not result.relevant?
      assert_nil result.conversation
    end
  end

  test "treats a shared customer address as ambiguous" do
    other_customer = @account.customers.create!(
      invoice_source: invoice_sources(:xero),
      customer_segment: customer_segments(:normal_debtor_segment),
      external_id: "matcher-other-customer",
      name: "Other matching customer",
      email: @customer.email
    )
    assert other_customer.persisted?

    result = match_email(parsed_message(from_address: @customer.email))

    assert_equal "ambiguous", result.matching_status
    assert_includes result.review_reasons, "duplicate_customer_address"
  end

  test "never crosses accounts for provider or RFC IDs" do
    other_account = Account.create!(name: "Matcher other account")
    other_conversation = other_account.conversations.create!
    other_conversation.conversation_messages.create!(
      account: other_account,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      provider_account_id: "other-google-account",
      provider_message_id: nil,
      provider_thread_id: "other-provider-thread",
      internet_message_id: "<other-rfc@example.com>",
      from_address: "stranger@example.net",
      to_addresses: [ "billing@example.com" ],
      cc_addresses: [],
      subject: "Other account",
      body: "Other account"
    )

    result = match_email(parsed_message(
      provider_thread_id: "other-provider-thread",
      in_reply_to_message_ids: [ "<other-rfc@example.com>" ],
      from_address: "stranger@example.net"
    ))

    assert_not result.relevant?
    assert_nil result.conversation
  end

  test "never crosses Gmail identities for provider threads or RFC headers" do
    other_identity_conversation = @account.conversations.create!
    other_identity_conversation.conversation_messages.create!(
      account: @account,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      provider_account_id: "replacement-google-account",
      provider_message_id: nil,
      provider_thread_id: "other-identity-thread",
      internet_message_id: "<other-identity-rfc@example.com>",
      from_address: "stranger@example.net",
      to_addresses: [ "billing@example.com" ],
      cc_addresses: [],
      subject: "Other identity",
      body: "Other identity"
    )

    result = match_email(parsed_message(
      provider_thread_id: "other-identity-thread",
      in_reply_to_message_ids: [ "<other-identity-rfc@example.com>" ],
      from_address: "stranger@example.net"
    ))

    assert_not result.relevant?
    assert_nil result.conversation
  end

  test "does not use ambiguous messages as Gmail or RFC conversation anchors" do
    connection = email_connections(:paid_jar_gmail)
    ambiguous_conversation = @account.conversations.create!
    ambiguous_conversation.conversation_messages.create!(
      account: @account,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: @provider_account_id,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      provider_message_id: "ambiguous-anchor",
      provider_thread_id: "ambiguous-thread",
      internet_message_id: "<ambiguous-anchor@example.net>",
      from_address: "stranger@example.net",
      to_addresses: [ "billing@example.com" ],
      cc_addresses: [],
      bcc_addresses: [],
      subject: "Ambiguous",
      body: "Ambiguous",
      matching_status: :ambiguous,
      matching_method: :none,
      review_required: true,
      review_reasons: [ "invoice_thread_conflict" ]
    )

    gmail_result = match_email(parsed_message(
      provider_thread_id: "ambiguous-thread",
      from_address: "another-stranger@example.net"
    ))
    rfc_result = match_email(parsed_message(
      provider_thread_id: "unrelated-thread",
      in_reply_to_message_ids: [ "<ambiguous-anchor@example.net>" ],
      from_address: "another-stranger@example.net"
    ))

    assert_not gmail_result.relevant?
    assert_nil gmail_result.conversation
    assert_not rfc_result.relevant?
    assert_nil rfc_result.conversation
  end

  test "uses an explicitly invoice-matched ambiguous message as a Gmail-thread anchor" do
    source, ambiguous = create_ambiguous_anchor(
      provider_message_id: "manual-gmail-anchor",
      provider_thread_id: "manual-gmail-thread",
      internet_message_id: "<manual-gmail-anchor@example.net>"
    )
    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: ambiguous,
      target_invoice: @invoice,
      actor_user: users(:arjun),
      work_unit_token: conversation_work_unit_token(source)
    )

    result = match_email(parsed_message(
      provider_thread_id: "manual-gmail-thread",
      from_address: "unknown-follow-up@example.net"
    ))

    assert_equal target, result.conversation
    assert_equal "matched", result.matching_status
    assert_equal "gmail_thread", result.matching_method
    assert_predicate ambiguous.reload, :matching_status_ambiguous?
    assert_predicate ambiguous, :review_outcome_manual_match?
  end

  test "uses an explicitly invoice-matched ambiguous message as an RFC anchor" do
    source, ambiguous = create_ambiguous_anchor(
      provider_message_id: "manual-rfc-anchor",
      provider_thread_id: "manual-rfc-source-thread",
      internet_message_id: "<manual-rfc-anchor@example.net>"
    )
    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: ambiguous,
      target_invoice: @invoice,
      actor_user: users(:arjun),
      work_unit_token: conversation_work_unit_token(source)
    )

    result = match_email(parsed_message(
      provider_thread_id: "manual-rfc-follow-up-thread",
      in_reply_to_message_ids: [ "<manual-rfc-anchor@example.net>" ],
      from_address: "unknown-follow-up@example.net"
    ))

    assert_equal target, result.conversation
    assert_equal "matched", result.matching_status
    assert_equal "rfc_headers", result.matching_method
    assert_predicate ambiguous.reload, :matching_status_ambiguous?
    assert_predicate ambiguous, :review_outcome_manual_match?
  end

  test "uses a corrected no-match review as both Gmail and RFC anchors" do
    source, ambiguous = create_ambiguous_anchor(
      provider_message_id: "corrected-review-anchor",
      provider_thread_id: "corrected-review-thread",
      internet_message_id: "<corrected-review-anchor@example.net>"
    )
    ConversationMessages::Review.complete!(
      conversation: source,
      message: ambiguous,
      actor_user: users(:arjun),
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(source)
    )
    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: ambiguous,
      target_invoice: @invoice,
      actor_user: users(:arjun),
      work_unit_token: conversation_work_unit_token(source)
    )

    gmail_result = match_email(parsed_message(
      provider_thread_id: "corrected-review-thread",
      from_address: "unknown-gmail-follow-up@example.net"
    ))
    rfc_result = match_email(parsed_message(
      provider_thread_id: "corrected-review-rfc-thread",
      in_reply_to_message_ids: [ "<corrected-review-anchor@example.net>" ],
      from_address: "unknown-rfc-follow-up@example.net"
    ))

    assert_equal target, gmail_result.conversation
    assert_equal "gmail_thread", gmail_result.matching_method
    assert_equal target, rfc_result.conversation
    assert_equal "rfc_headers", rfc_result.matching_method
  end

  private
    def match_email(parsed_message, direction: :inbound)
      ConversationMessages::EmailMatcher.call(
        account: @account,
        provider_account_id: @provider_account_id,
        parsed_message:,
        direction:
      )
    end

    def create_other_invoice(number:)
      @invoice.dup.tap do |invoice|
        invoice.external_id = "matcher-#{number.downcase}"
        invoice.number = number
        invoice.save!
      end
    end

    def create_ambiguous_anchor(
      provider_message_id:,
      provider_thread_id:,
      internet_message_id:
    )
      connection = email_connections(:paid_jar_gmail)
      conversation = @account.conversations.create!
      message = conversation.conversation_messages.create!(
        account: @account,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: @provider_account_id,
        provider_message_id:,
        provider_thread_id:,
        internet_message_id:,
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        from_address: "unknown-anchor@example.net",
        matching_status: :ambiguous,
        matching_method: :none,
        review_required: true,
        review_reasons: [ "invoice_thread_conflict" ]
      )
      [ conversation, message ]
    end

    def create_unmatched_thread(provider_thread_id)
      @account.conversations.create!(customer: @customer).tap do |conversation|
        conversation.conversation_messages.create!(
          account: @account,
          direction: :inbound,
          kind: :customer_email,
          status: :received,
          received_at: Time.current,
          provider_account_id: @provider_account_id,
          provider_message_id: "message-#{provider_thread_id}",
          provider_thread_id:,
          email_connection: email_connections(:paid_jar_gmail),
          email_connection_generation: email_connections(:paid_jar_gmail).credential_generation,
          from_address: @customer.email,
          to_addresses: [ "billing@paymentreminder.example" ],
          cc_addresses: [],
          subject: "General question",
          body: "Hello"
        )
      end
    end

    def parsed_message(attributes = {})
      defaults = {
        provider_message_id: SecureRandom.hex,
        provider_thread_id: SecureRandom.hex,
        internal_date: Time.current,
        label_ids: [],
        from_address: "stranger@example.net",
        to_addresses: [ "billing@paymentreminder.example" ],
        cc_addresses: [],
        bcc_addresses: [],
        reply_to_addresses: [],
        subject: "General message",
        body: "Hello",
        internet_message_id: "<#{SecureRandom.uuid}@example.net>",
        in_reply_to_message_ids: [],
        reference_message_ids: [],
        automatic: false,
        parse_warnings: []
      }
      EmailConnection::Gmail::MessageParser::ParsedMessage.new(**defaults.merge(attributes)).freeze
    end
end
