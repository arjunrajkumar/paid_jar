class EmailConnection::Delivery
  Result = Data.define(:provider_message_id, :provider_thread_id)

  def initialize(
    account:,
    connection:,
    provider_account_id:,
    credential_generation:,
    requested_provider_thread_id: nil
  )
    @account = account
    @connection = connection
    @provider_account_id = provider_account_id
    @credential_generation = credential_generation
    @requested_provider_thread_id = requested_provider_thread_id
  end

  def deliver(mail_message)
    provider_delivery.deliver(mail_message)
  end

  private
    attr_reader :account,
      :connection,
      :provider_account_id,
      :credential_generation,
      :requested_provider_thread_id

    def provider_delivery
      delivery_arguments = {
        account:,
        connection:,
        provider_account_id:,
        credential_generation:
      }
      if requested_provider_thread_id.present?
        delivery_arguments[:requested_provider_thread_id] = requested_provider_thread_id
      end
      provider_delivery_class.new(**delivery_arguments)
    end

    def provider_delivery_class
      "EmailConnection::#{connection.provider.classify}::Delivery".constantize
    end
end
