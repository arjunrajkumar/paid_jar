require "test_helper"

class ConversationMessages::ProviderDeliveryTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @connection = email_connections(:paid_jar_gmail)
    @mail_message = Mail.new(
      from: "billing@paymentreminder.example",
      to: "customer@example.com",
      subject: "Payment reminder",
      body: "Please pay your invoice."
    )
  end

  test "wraps outbound delivery and returns confirmed provider metadata" do
    provider_result = EmailConnection::Delivery::Result.new(
      provider_message_id: " gmail-message-123 ",
      provider_thread_id: " gmail-thread-456 "
    )
    delivery = mock
    EmailConnection::Delivery.expects(:new).with(
      account: @account,
      connection: @connection
    ).returns(delivery)
    delivery.expects(:deliver).with(@mail_message).returns(provider_result)

    result = deliver

    assert_predicate result, :confirmed?
    assert_equal "gmail-message-123", result.provider_message_id
    assert_equal "gmail-thread-456", result.provider_thread_id
    assert_nil result.failure_reason
  end

  test "accepts a provider message ID returned as a string" do
    result = deliver { "gmail-message-123" }

    assert_predicate result, :confirmed?
    assert_equal "gmail-message-123", result.provider_message_id
    assert_nil result.provider_thread_id
  end

  test "returns a terminal failure when the provider does not confirm a message ID" do
    provider_result = EmailConnection::Delivery::Result.new(
      provider_message_id: " ",
      provider_thread_id: "unconfirmed-thread"
    )

    result = deliver { provider_result }

    assert_not_predicate result, :confirmed?
    assert_nil result.provider_message_id
    assert_nil result.provider_thread_id
    assert_equal ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
      result.failure_reason
  end

  test "re-raises retry-safe temporary delivery errors" do
    error = EmailConnection::Errors::TemporaryDeliveryError.new("rate limited")
    Sentry.expects(:capture_exception).never

    raised = assert_raises EmailConnection::Errors::TemporaryDeliveryError do
      deliver { raise error }
    end

    assert_same error, raised
  end

  test "reports authentication errors with caller context and returns a terminal failure" do
    error = EmailConnection::Errors::AuthenticationError.new("invalid_grant")
    Sentry.expects(:capture_exception).with(
      error,
      tags: {
        provider: "gmail",
        operation: "invoice_reminder_delivery"
      },
      extra: {
        account_id: @account.id,
        invoice_id: 123
      }
    )

    result = deliver { raise error }

    assert_not_predicate result, :confirmed?
    assert_equal "invalid_grant", result.failure_reason
  end

  test "turns ambiguous and other provider errors into terminal failures" do
    ambiguous = EmailConnection::Errors::AmbiguousDeliveryError.new("response lost")
    permanent = EmailConnection::Errors::PermanentDeliveryError.new("invalid recipient")
    unexpected = StandardError.new("provider adapter failed")

    ambiguous_result = deliver { raise ambiguous }
    permanent_result = deliver { raise permanent }
    unexpected_result = deliver { raise unexpected }

    assert_not_predicate ambiguous_result, :confirmed?
    assert_equal "response lost", ambiguous_result.failure_reason
    assert_not_predicate permanent_result, :confirmed?
    assert_equal "invalid recipient", permanent_result.failure_reason
    assert_not_predicate unexpected_result, :confirmed?
    assert_equal "provider adapter failed", unexpected_result.failure_reason
  end

  private
    def deliver(&delivery)
      ConversationMessages::ProviderDelivery.call(
        account: @account,
        connection: @connection,
        mail_message: @mail_message,
        operation: "invoice_reminder_delivery",
        context: {
          account_id: @account.id,
          invoice_id: 123
        },
        &delivery
      )
    end
end
