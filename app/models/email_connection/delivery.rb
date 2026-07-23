class EmailConnection::Delivery
  Result = Data.define(:provider_message_id, :provider_thread_id)

  def initialize(account:, connection:, provider_account_id:, credential_generation:)
    @account = account
    @connection = connection
    @provider_account_id = provider_account_id
    @credential_generation = credential_generation
  end

  def deliver(mail_message)
    provider_delivery.deliver(mail_message)
  end

  private
    attr_reader :account, :connection, :provider_account_id, :credential_generation

    def provider_delivery
      provider_delivery_class.new(
        account:,
        connection:,
        provider_account_id:,
        credential_generation:
      )
    end

    def provider_delivery_class
      "EmailConnection::#{connection.provider.classify}::Delivery".constantize
    end
end
