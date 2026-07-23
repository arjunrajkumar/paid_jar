require "test_helper"

class Conversations::DetailTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @connection = email_connections(:paid_jar_gmail)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
  end

  test "provides the newest safe reply target and exact recipient for each Gmail thread" do
    first = create_inbound(
      provider_message_id: "detail-first",
      provider_thread_id: "detail-thread-one",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    create_inbound(
      provider_message_id: "detail-automatic",
      provider_thread_id: "detail-thread-one",
      received_at: Time.zone.local(2026, 7, 22, 11),
      automatic: true,
      review_required: true
    )
    second = create_inbound(
      provider_message_id: "detail-second",
      provider_thread_id: "detail-thread-two",
      received_at: Time.zone.local(2026, 7, 22, 12),
      reply_to_addresses: [ @invoice.customer.email ]
    )

    targets = Conversations::Detail.call(conversation: @conversation).reply_targets

    assert_equal [ first, second ], targets.map(&:message)
    assert_equal [ @invoice.customer.email, @invoice.customer.email ],
      targets.map(&:recipient)
  end

  test "does not offer reply targets from a replaced stable Gmail identity" do
    create_inbound(
      provider_message_id: "old-identity-message",
      provider_thread_id: "old-identity-thread",
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    @connection.update_column(:provider_account_id, "replacement-google-identity")

    assert_empty Conversations::Detail.call(
      conversation: @conversation
    ).reply_targets
  end

  private
    def create_inbound(
      provider_message_id:,
      provider_thread_id:,
      received_at:,
      automatic: false,
      review_required: false,
      reply_to_addresses: []
    )
      @conversation.conversation_messages.create!(
        account: @account,
        invoice: @invoice,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id:,
        internet_message_id: "<#{provider_message_id}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at:,
        from_address: @invoice.customer.email,
        reply_to_addresses:,
        subject: "Question",
        matching_status: review_required ? :unmatched : :matched,
        matching_method: review_required ? :none : :gmail_thread,
        review_required:,
        review_reasons: review_required ? [ "automatic_response" ] : [],
        automatic:
      )
    end
end
