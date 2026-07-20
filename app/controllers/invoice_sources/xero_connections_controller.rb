module InvoiceSources
  class XeroConnectionsController < ApplicationController
    include ::Xero::OauthFlow

    before_action :set_request_account, only: %i[new destroy]
    before_action :ensure_xero_configured, only: :new
    before_action :set_xero_source, only: :destroy

    def new
      start_xero_oauth(
        flow: :connection,
        redirect_uri: xero_configuration.redirect_uri,
        scopes: xero_configuration.scopes,
        context: {
          "account_id" => @connection_account.id,
          "identity_id" => Current.identity.id
        }
      )
    end

    def create
      authorization = finish_xero_oauth(
        flow: :connection,
        redirect_uri: xero_configuration.redirect_uri,
        include_connections: true
      ) do |context|
        verify_connection_context!(context)
      end
      result = ::Xero::AccountConnection.new(
        account: @connection_account,
        identity: Current.identity,
        authorization:
      ).complete!
      queue_initial_refresh(result.invoice_source)

      redirect_to connection_settings_url,
        notice: "Xero connected. Your invoices are syncing now."
    rescue ::Xero::OauthFlow::Error, ::Xero::Authorization::Error,
      ::Xero::AccountConnection::Error => error
      handle_connection_error(error)
    rescue ActiveRecord::ActiveRecordError, KeyError => error
      Rails.error.report(error, severity: :error)
      handle_connection_error(
        ::Xero::OauthFlow::Error.new("Xero could not be connected securely. Please try again.")
      )
    end

    def destroy
      InvoiceSources::Xero.new(@invoice_source).disconnect!
      redirect_to connection_settings_url, notice: "Xero disconnected."
    rescue InvoiceSources::Xero::OauthClient::Error, InvoiceSources::Xero::DisconnectError => error
      Rails.error.report(error, severity: :warning)
      redirect_to connection_settings_url,
        alert: "Xero could not be disconnected. Please try again."
    end

    private
      def set_request_account
        external_account_id = request.env["paidjar.external_account_id"]
        account = Account.find_by!(external_account_id:)
        @connection_account = Current.identity.users.active.find_by!(account_id: account.id).account
      rescue ActiveRecord::RecordNotFound
        redirect_to root_url, alert: "Choose a PaymentReminder account you can access."
      end

      def ensure_xero_configured
        return if xero_configuration.configured?

        redirect_to connection_settings_url,
          alert: "Xero credentials are not configured."
      end

      def set_xero_source
        @invoice_source = @connection_account.invoice_sources.xero.first
        return if @invoice_source.present?

        redirect_to new_xero_connection_url(script_name: @connection_account.slug),
          alert: "Connect Xero first."
      end

      def verify_connection_context!(context)
        account_id = context&.fetch(:account_id, nil)
        identity_id = context&.fetch(:identity_id, nil)
        valid_identity = identity_id.present? && Current.identity.id == identity_id.to_i
        membership = Current.identity.users.active.find_by(account_id: account_id)
        scoped_account_matches = request.env["paidjar.external_account_id"].blank? ||
          membership&.account&.external_account_id == request.env["paidjar.external_account_id"]

        unless valid_identity && membership.present? && scoped_account_matches
          raise ::Xero::OauthFlow::Error, "Xero connection could not be verified."
        end

        @connection_account = membership.account
      end

      def connection_settings_url
        account = @connection_account || account_from_oauth_context
        return root_url if account.blank?

        account_settings_url(script_name: account.slug)
      end

      def account_from_oauth_context
        context = xero_oauth_context
        return if context.blank? || context[:identity_id].to_i != Current.identity.id

        Current.identity.users.active.find_by(account_id: context[:account_id])&.account
      end

      def queue_initial_refresh(source)
        InvoiceSources::RefreshJob.perform_later(source)
      rescue ActiveJob::EnqueueError => error
        Rails.error.report(error, severity: :error)
      end

      def handle_connection_error(error)
        redirect_to connection_settings_url, alert: error.message
      end
  end
end
