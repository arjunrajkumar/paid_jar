module InvoiceSources
  class Xero
    class DisconnectError < StandardError; end

    attr_reader :source

    def initialize(source)
      @source = source
    end

    def connect_from_authorization!(token_set:, connection:, identity:, authentication_event_id:)
      source.update!(
        provider: :xero,
        status: :active,
        external_account_id: connection.fetch("tenantId"),
        external_account_name: connection.fetch("tenantName"),
        access_token: token_set.fetch("access_token"),
        refresh_token: token_set.fetch("refresh_token"),
        expires_at: Time.current + token_set.fetch("expires_in").to_i.seconds,
        scopes: token_set["scope"].to_s.split,
        provider_data: {
          xero_user_id: identity.subject,
          email: identity.email,
          token_type: token_set.fetch("token_type", "Bearer"),
          connection_id: connection["id"],
          authentication_event_id: authentication_event_id
        }.compact,
        raw_token_data: InvoiceSource.sanitized_token_data(token_set),
        last_error: nil
      )

      source
    end

    def sync_invoices!
      ensure_access_token!
      InvoiceSync.new(source, client: oauth_client).sync!
    end

    def sync_invoice!(external_id:)
      ensure_access_token!
      InvoiceSync.new(source, client: oauth_client).sync_invoice_by_id!(external_id)
    end

    def connected?
      source.active? && source.external_account_id.present? && source.refresh_token.present?
    end

    def refreshable?
      (source.active? || source.error?) &&
        source.external_account_id.present? &&
        source.refresh_token.present?
    end

    def refresh_access_token!
      token_set = oauth_client.refresh_token(refresh_token: source.refresh_token)

      source.update!(
        access_token: token_set.fetch("access_token"),
        refresh_token: token_set.fetch("refresh_token"),
        expires_at: Time.current + token_set.fetch("expires_in").to_i.seconds,
        scopes: token_set["scope"].present? ? token_set["scope"].to_s.split : source.scopes,
        raw_token_data: InvoiceSource.sanitized_token_data(token_set),
        status: :active,
        last_error: nil
      )
    end

    def disconnect!
      connection_id = connection_id!
      ensure_access_token!
      oauth_client.disconnect_connection(
        access_token: source.access_token,
        connection_id:
      )
      clear_local_tokens!

      source
    rescue DisconnectError, OauthClient::Error => error
      source.update!(status: :error, last_error: error.message)
      raise
    end

    private
      def connection_id!
        connection_id = saved_connection_id || legacy_connection_id
        return connection_id if connection_id.present?

        raise DisconnectError, "Xero connection ID is missing."
      end

      def saved_connection_id
        provider_data["connection_id"].presence
      end

      def legacy_connection_id
        connection = Array(provider_data["connections"]).find do |candidate|
          candidate.with_indifferent_access["tenantId"].to_s == source.external_account_id.to_s
        end

        connection&.with_indifferent_access&.[]("id").presence
      end

      def provider_data
        source.provider_data.to_h.with_indifferent_access
      end

      def clear_local_tokens!
        source.update!(
          status: :disconnected,
          access_token: nil,
          refresh_token: nil,
          expires_at: nil,
          raw_token_data: {},
          last_error: nil
        )
      end

      def ensure_access_token!
        refresh_access_token! if source.expired?
      end

      def oauth_client
        @oauth_client ||= OauthClient.new
      end
  end
end
