class EmailConnection::InboxHealth
  DELAYED_AFTER = 1.hour
  INITIAL_SYNC_GRACE = 1.hour

  State = Data.define(:state, :message, :action_required)
  Result = Data.define(
    :connected_email,
    :last_successful_inbound_sync_at,
    :receiving,
    :sending
  ) do
    def action_required?
      receiving.action_required || sending.action_required
    end
  end

  def self.call(account:, at: Time.current)
    new(account:, at:).call
  end

  def initialize(account:, at:)
    @account = account
    @at = at
  end

  def call
    connection = account.email_connection

    Result.new(
      connected_email: connection&.connected_email,
      last_successful_inbound_sync_at: connection&.last_inbound_synced_at,
      receiving: receiving_state(connection),
      sending: sending_state(connection)
    )
  end

  private
    attr_reader :account, :at

    def receiving_state(connection)
      return state(:not_connected, "Connect Gmail to receive customer replies.", true) unless connection
      return state(:disconnected, "Gmail is disconnected.", true) if connection.disconnected?
      return state(:authentication_required, "Gmail needs to be reconnected.", true) if connection.errored?
      return state(:temporarily_failing, "Gmail receiving is temporarily unavailable.", true) unless connection.inbound_ready?

      if connection.last_inbound_synced_at.nil?
        if connection.inbound_enabled_at.present? &&
            connection.inbound_enabled_at >= INITIAL_SYNC_GRACE.ago(at)
          return state(:initial_sync_pending, "The first Inbox sync is pending.", false)
        end

        return state(:delayed, "Gmail has not completed its first Inbox sync.", true)
      end

      if connection.last_inbound_synced_at < DELAYED_AFTER.ago(at)
        return state(:delayed, "Gmail receiving is delayed.", true)
      end
      if connection.last_inbound_error.present?
        return state(:temporarily_failing, "Gmail receiving is temporarily unavailable.", false)
      end

      state(:healthy, "Gmail receiving is healthy.", false)
    end

    def sending_state(connection)
      return state(:not_connected, "Connect Gmail to send replies.", true) unless connection
      return state(:disconnected, "Gmail is disconnected.", true) if connection.disconnected?
      return state(:authentication_required, "Gmail needs to be reconnected.", true) if connection.errored?
      unless connection.gmail_ready? &&
          connection.sender_matches?(account.invoice_reminder_from_email)
        return state(:temporarily_failing, "Gmail sending is temporarily unavailable.", true)
      end

      state(:healthy, "Gmail sending is healthy.", false)
    end

    def state(value, message, action_required)
      State.new(state: value.to_s, message:, action_required:)
    end
end
