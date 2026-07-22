module InvoiceSources
  class Stripe
    AUTHORIZATION_TYPE = "stripe_app_platform"

    class ConnectionError < StandardError; end
    class AccountConflictError < ConnectionError; end
    class AccountMismatchError < ConnectionError; end
    class ModeConflictError < ConnectionError; end

    LIFECYCLE_EVENT_AT_KEY = "lifecycle_event_at"
    LIFECYCLE_EVENT_TYPE_KEY = "lifecycle_event_type"

    attr_reader :source

    def initialize(source)
      @source = source
    end

    def connect_from_install!(stripe_account_id:, stripe_user_id:, livemode:, config: Configuration.new, client: nil)
      ensure_account_available!(stripe_account_id)
      ensure_source_matches!(stripe_account_id:, livemode:)
      (client || ApiClient.new(livemode:, config:)).verify_access!(stripe_account_id:)
      authorization_timestamp = Time.current.iso8601

      source.update!(
        provider: :stripe,
        status: :active,
        external_account_id: stripe_account_id,
        external_account_name: stripe_account_id,
        access_token: nil,
        refresh_token: nil,
        expires_at: nil,
        scopes: config.permissions,
        provider_data: {
          authorization_type: AUTHORIZATION_TYPE,
          app_id: config.app_id,
          stripe_user_id:,
          livemode:,
          authorized_at: authorization_timestamp,
          LIFECYCLE_EVENT_AT_KEY => authorization_timestamp,
          LIFECYCLE_EVENT_TYPE_KEY => WebhookEvent::APPLICATION_AUTHORIZED_EVENT_TYPE
        },
        raw_token_data: {},
        last_error: nil
      )

      source
    rescue ActiveRecord::RecordNotUnique
      raise AccountConflictError, "This Stripe account is already connected to another PaymentReminder workspace."
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record == source

      if error.record.errors.of_kind?(:provider, :taken)
        raise AccountMismatchError, "This PaymentReminder workspace already has a Stripe connection."
      end
      raise unless error.record.errors.of_kind?(:external_account_id, :taken)

      raise AccountConflictError, "This Stripe account is already connected to another PaymentReminder workspace."
    end

    def authorize_from_webhook!(occurred_at:)
      event_time = occurred_at || Time.current
      source.with_lock do
        applies = lifecycle_event_applies?(
          event_type: WebhookEvent::APPLICATION_AUTHORIZED_EVENT_TYPE,
          occurred_at: event_time
        )
        if applies
          source.update!(
            status: :active,
            provider_data: source.provider_data.merge(
              "authorized_at" => event_time.iso8601,
              LIFECYCLE_EVENT_AT_KEY => event_time.iso8601,
              LIFECYCLE_EVENT_TYPE_KEY => WebhookEvent::APPLICATION_AUTHORIZED_EVENT_TYPE
            ),
            last_error: nil
          )
        end
        applies
      end
    end

    def deauthorize_from_webhook!(occurred_at:)
      event_time = occurred_at || Time.current
      source.with_lock do
        applies = lifecycle_event_applies?(
          event_type: WebhookEvent::APPLICATION_DEAUTHORIZED_EVENT_TYPE,
          occurred_at: event_time
        )
        if applies
          source.update!(
            status: :disconnected,
            access_token: nil,
            refresh_token: nil,
            expires_at: nil,
            raw_token_data: {},
            provider_data: source.provider_data.merge(
              "deauthorized_at" => event_time.iso8601,
              LIFECYCLE_EVENT_AT_KEY => event_time.iso8601,
              LIFECYCLE_EVENT_TYPE_KEY => WebhookEvent::APPLICATION_DEAUTHORIZED_EVENT_TYPE
            ),
            last_error: nil
          )
        end
        applies
      end
    end

    def sync_invoices!
      InvoiceSync.new(source, client: api_client).sync!
    end

    def sync_invoice!(external_id:)
      InvoiceSync.new(source, client: api_client).sync_invoice_by_id!(external_id)
    end

    def connected?
      source.active? && source.external_account_id.present?
    end

    def refreshable?
      (source.active? || source.error?) && source.external_account_id.present?
    end

    def livemode?
      source.provider_data.fetch("livemode", true)
    end

    private
      def api_client
        @api_client ||= ApiClient.new(livemode: livemode?)
      end

      def ensure_account_available!(stripe_account_id)
        existing_source = InvoiceSource.find_by(provider: :stripe, external_account_id: stripe_account_id)
        return if existing_source.nil? || existing_source == source

        raise AccountConflictError, "This Stripe account is already connected to another PaymentReminder workspace."
      end

      def ensure_source_matches!(stripe_account_id:, livemode:)
        if source.external_account_id.present? && source.external_account_id != stripe_account_id
          raise AccountMismatchError, "This workspace was previously connected to a different Stripe account."
        end

        return unless source.persisted? && source.provider_data.key?("livemode")
        return if source.disconnected?
        return if source.provider_data.fetch("livemode") == livemode

        raise ModeConflictError, "This workspace is already connected to Stripe in a different environment."
      end

      def lifecycle_event_applies?(event_type:, occurred_at:)
        previous_time = previous_lifecycle_event_time
        return true unless previous_time
        return true if occurred_at > previous_time
        return false if occurred_at < previous_time

        event_type == WebhookEvent::APPLICATION_DEAUTHORIZED_EVENT_TYPE &&
          source.provider_data[LIFECYCLE_EVENT_TYPE_KEY] != event_type
      end

      def previous_lifecycle_event_time
        value = source.provider_data[LIFECYCLE_EVENT_AT_KEY]
        Time.iso8601(value) if value.present?
      rescue ArgumentError
        nil
      end
  end
end
