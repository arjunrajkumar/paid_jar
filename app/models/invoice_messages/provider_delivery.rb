class InvoiceMessages::ProviderDelivery
  UNCONFIRMED_FAILURE_REASON = "Email provider did not confirm delivery."

  Result = Data.define(
    :provider_message_id,
    :provider_thread_id,
    :failure_reason
  ) do
    def confirmed?
      provider_message_id.present?
    end
  end

  def self.call(
    account:,
    connection:,
    mail_message:,
    operation:,
    context:,
    &delivery
  )
    new(
      account:,
      connection:,
      mail_message:,
      operation:,
      context:,
      delivery:
    ).call
  end

  def initialize(
    account:,
    connection:,
    mail_message:,
    operation:,
    context:,
    delivery: nil
  )
    @account = account
    @connection = connection
    @mail_message = mail_message
    @operation = operation
    @context = context
    @delivery = delivery
  end

  def call
    confirmed_result(deliver)
  rescue OutboundEmailConnection::Errors::TemporaryDeliveryError
    raise
  rescue OutboundEmailConnection::Errors::AuthenticationError => error
    report_authentication_failure(error)
    failed_result(error.message)
  rescue StandardError => error
    failed_result(error.message)
  end

  private
    attr_reader :account, :connection, :mail_message, :operation, :context, :delivery

    def deliver
      return delivery.call(mail_message) if delivery

      OutboundEmailConnection::Delivery.new(
        account:,
        connection:
      ).deliver(mail_message)
    end

    def confirmed_result(delivery_result)
      message_id = provider_message_id(delivery_result)
      return failed_result(UNCONFIRMED_FAILURE_REASON) unless message_id

      Result.new(
        provider_message_id: message_id,
        provider_thread_id: provider_thread_id(delivery_result),
        failure_reason: nil
      )
    end

    def failed_result(failure_reason)
      Result.new(
        provider_message_id: nil,
        provider_thread_id: nil,
        failure_reason:
      )
    end

    def provider_message_id(delivery_result)
      value = if delivery_result.respond_to?(:provider_message_id)
        delivery_result.provider_message_id
      elsif delivery_result.is_a?(String)
        delivery_result
      end
      normalize_provider_id(value)
    end

    def provider_thread_id(delivery_result)
      return unless delivery_result.respond_to?(:provider_thread_id)

      normalize_provider_id(delivery_result.provider_thread_id)
    end

    def normalize_provider_id(value)
      value.to_s.strip.presence
    end

    def report_authentication_failure(error)
      Sentry.capture_exception(
        error,
        tags: {
          provider: connection.provider.to_s,
          operation:
        },
        extra: context
      )
    end
end
