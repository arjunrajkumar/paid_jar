module EmailConnections
  class GmailConnectionsController < ApplicationController
    require_account_admin

    prepend_before_action :restore_oauth_account_from_state, only: :create
    before_action :ensure_google_configured, only: %i[new create]
    before_action :ensure_google_approved, only: :create
    before_action :ensure_oauth_state, only: :create
    before_action :set_connection, only: %i[destroy test]

    def new
      nonce = SecureRandom.urlsafe_base64(32)
      session[:gmail_oauth_nonce] = nonce
      state = EmailConnection::Gmail::OauthState.issue(account: Current.account, nonce:)

      redirect_to oauth_client.authorization_url(
        state:,
        redirect_uri: gmail_callback_url(script_name: nil)
      ), allow_other_host: true
    end

    def create
      token_data = oauth_client.exchange_code(
        code: params.require(:code),
        redirect_uri: gmail_callback_url(script_name: nil)
      )
      scopes = token_data.fetch("scope", "").split
      validate_required_scopes!(scopes)
      access_token = token_data.fetch("access_token")
      userinfo = oauth_client.userinfo(access_token:)
      gmail_profile = oauth_client.gmail_profile(access_token:)
      provider_account_id = userinfo.fetch("id").to_s.presence || raise(KeyError, "missing Google account ID")
      connected_email = gmail_profile.email_address.to_s.presence || raise(KeyError, "missing Gmail address")
      history_id = gmail_profile.history_id.to_s.presence || raise(KeyError, "missing Gmail history ID")
      unless userinfo.fetch("email").to_s.casecmp?(connected_email)
        raise EmailConnection::Errors::AuthorizationError, "Google identity did not match the Gmail profile."
      end
      connection = Current.account.email_connection ||
        Current.account.build_email_connection(provider: :gmail, connected_email: connected_email)

      connection.connect_gmail!(
        email: connected_email,
        name: userinfo["name"],
        provider_account_id:,
        history_id:,
        access_token:,
        refresh_token: token_data["refresh_token"],
        expires_at: Time.current + token_data.fetch("expires_in").to_i.seconds,
        scopes:
      )
      enqueue_initial_inbound_sync(connection)

      redirect_to account_settings_path(script_name: Current.account.slug), notice: "Gmail connected."
    rescue KeyError, ActiveRecord::RecordInvalid, EmailConnection::Errors::Error => error
      log_connection_error(error)
      redirect_to account_settings_path(script_name: Current.account.slug),
        alert: "Gmail connection failed: #{error.message}"
    ensure
      session.delete(:gmail_oauth_nonce)
    end

    def destroy
      @connection.disconnect!
      redirect_to account_settings_path(script_name: Current.account.slug), notice: "Gmail disconnected."
    end

    def test
      mail_message = Mail.new(
        to: Current.identity.email_address,
        subject: "PaymentReminder Gmail connection test",
        body: "Your PaymentReminder invoice reminder connection is working."
      )
      EmailConnection::Delivery.new(
        account: Current.account,
        connection: @connection,
        provider_account_id: @connection.provider_account_id,
        credential_generation: @connection.credential_generation
      ).deliver(mail_message)

      redirect_to account_settings_path(script_name: Current.account.slug), notice: "Test email sent."
    rescue EmailConnection::Errors::Error => error
      redirect_to account_settings_path(script_name: Current.account.slug),
        alert: "Test email failed: #{error.message}"
    end

    private
      def account_access_denied_message
        "Gmail connection could not be verified."
      end

      def restore_oauth_account_from_state
        account_id = EmailConnection::Gmail::OauthState.account_id(
          params[:state],
          nonce: session[:gmail_oauth_nonce]
        )
        Current.account = Account.find_by(id: account_id) if account_id
      end

      def ensure_google_configured
        return if gmail_configuration.configured?

        redirect_to account_settings_path(script_name: Current.account.slug),
          alert: "Google credentials are not configured."
      end

      def ensure_google_approved
        return if params[:error].blank?

        session.delete(:gmail_oauth_nonce)
        redirect_to account_settings_path(script_name: Current.account.slug),
          alert: "Gmail connection was not approved."
      end

      def ensure_oauth_state
        valid_state = request_account_matches_current? && EmailConnection::Gmail::OauthState.valid?(
          params[:state],
          account: Current.account,
          nonce: session[:gmail_oauth_nonce]
        )
        session.delete(:gmail_oauth_nonce)
        return if valid_state

        redirect_to account_settings_path(script_name: Current.account.slug),
          alert: "Gmail connection could not be verified."
      end

      def request_account_matches_current?
        request_account_id = request.env["paidjar.external_account_id"]
        request_account_id.nil? || request_account_id == Current.account.external_account_id
      end

      def set_connection
        @connection = Current.account.email_connection
        return if @connection.present?

        redirect_to new_gmail_connection_path(script_name: Current.account.slug),
          alert: "Connect Gmail first."
      end

      def oauth_client
        @oauth_client ||= EmailConnection::Gmail::OauthClient.new(config: gmail_configuration)
      end

      def gmail_configuration
        @gmail_configuration ||= EmailConnection::Gmail::Configuration.new
      end

      def validate_required_scopes!(scopes)
        return if EmailConnection::Gmailable.required_scopes_granted?(scopes)

        raise EmailConnection::Errors::AuthorizationError, "Google did not grant all required Gmail permissions."
      end

      def enqueue_initial_inbound_sync(connection)
        EmailConnections::SyncInboundJob.enqueue(connection)
      rescue StandardError => error
        Rails.error.report(error, severity: :error)
        Rails.logger.error(
          "email.gmail_initial_sync_enqueue_failed " \
            "account_id=#{Current.account.id} error=#{error.class.name}"
        )
      end

      def log_connection_error(error)
        Rails.logger.error(
          "email.gmail_connection_failed " \
            "account_id=#{Current.account.id} error=#{error.class.name}"
        )
      end
  end
end
