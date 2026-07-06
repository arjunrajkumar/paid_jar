module AccountingIntegrations
  class Xero
    attr_reader :integration

    def initialize(integration)
      @integration = integration
    end

    def connect!(code:)
      token_set = oauth_client.exchange_code(code: code)
      connections = oauth_client.connections(access_token: token_set.fetch("access_token"))
      userinfo = oauth_client.userinfo(access_token: token_set.fetch("access_token"))
      primary_connection = connections.first || {}

      integration.update!(
        provider: :xero,
        status: :active,
        external_account_id: primary_connection.fetch("tenantId"),
        external_account_name: primary_connection["tenantName"],
        access_token: token_set.fetch("access_token"),
        refresh_token: token_set.fetch("refresh_token"),
        expires_at: Time.current + token_set.fetch("expires_in").to_i.seconds,
        scopes: token_set["scope"].to_s.split,
        provider_data: {
          xero_user_id: userinfo["xero_userid"] || userinfo["sub"],
          email: userinfo["email"],
          token_type: token_set.fetch("token_type", "Bearer"),
          connections: connections
        },
        raw_token_data: token_set,
        last_error: nil
      )
    end

    def sync_invoices!
      ensure_access_token!
      InvoiceSync.new(integration, client: oauth_client).sync!
    end

    def refresh_access_token!
      token_set = oauth_client.refresh_token(refresh_token: integration.refresh_token)

      integration.update!(
        access_token: token_set.fetch("access_token"),
        refresh_token: token_set.fetch("refresh_token"),
        expires_at: Time.current + token_set.fetch("expires_in").to_i.seconds,
        scopes: token_set["scope"].present? ? token_set["scope"].to_s.split : integration.scopes,
        raw_token_data: token_set,
        status: :active,
        last_error: nil
      )
    end

    private
      def ensure_access_token!
        refresh_access_token! if integration.expired?
      end

      def oauth_client
        @oauth_client ||= OauthClient.new
      end
  end
end
