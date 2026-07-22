class OutboundEmailConnection::DeliveryAvailability
  MISSING_CONNECTION = "missing_outbound_email_connection"
  SENDER_ADDRESS_MISMATCH = "sender_address_mismatch"

  Result = Data.define(:connection, :reason) do
    def ready?
      connection.present?
    end
  end

  def self.call(account:)
    new(account:).call
  end

  def initialize(account:)
    @account = account
  end

  def call
    account.reload
    connection = account.outbound_email_connection&.reload

    return unavailable(MISSING_CONNECTION) unless connection&.active? && connection.account_id == account.id
    return unavailable(SENDER_ADDRESS_MISMATCH) unless connection.sender_matches?(account.invoice_reminder_from_email)

    Result.new(connection:, reason: nil)
  end

  private
    attr_reader :account

    def unavailable(reason)
      Result.new(connection: nil, reason:)
    end
end
