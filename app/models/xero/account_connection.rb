module Xero
  class AccountConnection
    class Error < StandardError; end
    class ConnectionError < Error; end
    class IdentityConflictError < Error; end
    class TenantConflictError < Error; end

    Result = Data.define(:external_identity, :invoice_source)

    def initialize(account:, identity:, authorization:, platform_admin_impersonated_user: nil)
      @account = account
      @identity = identity
      @authorization = authorization
      @platform_admin_impersonated_user = platform_admin_impersonated_user
    end

    def complete!
      validate_active_membership!
      connection = sole_current_organization_connection!
      validate_accounting_token_set!
      validate_identity_link!
      validate_tenant_assignment!(connection)

      external_identity = invoice_source = nil

      ApplicationRecord.transaction do
        external_identity = link_external_identity!
        invoice_source = connect_source!(connection)
      end

      Result.new(external_identity:, invoice_source:)
    rescue ActiveRecord::RecordNotUnique
      raise_conflict_error!(connection)
    rescue ActiveRecord::RecordInvalid => error
      raise_record_conflict!(error, connection)
    end

    private
      attr_reader :account, :identity, :authorization, :platform_admin_impersonated_user

      def validate_active_membership!
        return if identity.users.active.exists?(account_id: account.id)
        return if exact_platform_admin_impersonation?

        raise ConnectionError, "You no longer have access to that PaymentReminder account."
      end

      def exact_platform_admin_impersonation?
        identity.platform_admin? &&
          platform_admin_impersonated_user&.active? &&
          platform_admin_impersonated_user.account_id == account.id
      end

      def sole_current_organization_connection!
        authentication_event_id = authorization.authentication_event_id.to_s.presence
        raise ConnectionError, connection_selection_message if authentication_event_id.blank?

        connections = Array(authorization.connections).select do |connection|
          organization_connection?(connection) &&
            same_authentication_event?(connection["authEventId"], authentication_event_id)
        end
        raise ConnectionError, connection_selection_message unless connections.one?

        connections.sole.tap do |connection|
          required_connection_values = %w[id tenantId tenantName].map { |key| connection[key].presence }
          raise ConnectionError, "Xero did not return a complete organization connection." if required_connection_values.any?(&:blank?)
        end
      end

      def organization_connection?(connection)
        connection["tenantType"].to_s.casecmp?("ORGANISATION")
      end

      def same_authentication_event?(connection_event_id, authentication_event_id)
        connection_event_id.present? && ActiveSupport::SecurityUtils.secure_compare(
          connection_event_id.to_s,
          authentication_event_id
        )
      end

      def validate_accounting_token_set!
        %w[access_token refresh_token expires_in].each do |key|
          raise KeyError if authorization.token_set.fetch(key).blank?
        end
      rescue KeyError
        raise ConnectionError, "Xero did not return the credentials needed to sync invoices."
      end

      def validate_identity_link!
        subject = authorization.identity.subject.to_s.presence
        raise ConnectionError, "Xero did not return a verified identity." if subject.blank?

        linked_identity = ExternalIdentity.xero.find_by(subject:)&.identity
        if linked_identity.present? && linked_identity != identity
          raise IdentityConflictError, "That Xero identity is already linked to another PaymentReminder account."
        end

        existing_subject = identity.external_identities.xero.pick(:subject)
        if existing_subject.present? && existing_subject != subject
          raise IdentityConflictError, "This PaymentReminder login is already linked to a different Xero identity."
        end
      end

      def validate_tenant_assignment!(connection)
        tenant_id = connection.fetch("tenantId")
        source = account.invoice_sources.xero.first

        if source.present? && source.external_account_id != tenant_id
          raise ConnectionError, "This account is already connected to a different Xero organization."
        end

        if InvoiceSource.xero.where(external_account_id: tenant_id).where.not(account_id: account.id).exists?
          raise TenantConflictError, tenant_conflict_message
        end
      end

      def link_external_identity!
        external_identity = identity.external_identities.xero.first_or_initialize
        external_identity.assign_attributes(
          subject: authorization.identity.subject,
          email_address: authorization.identity.email
        )
        external_identity.save!
        external_identity
      end

      def connect_source!(connection)
        source = account.invoice_sources.find_or_initialize_by(provider: :xero)
        InvoiceSources::Xero.new(source).connect_from_authorization!(
          token_set: authorization.token_set,
          connection:,
          identity: authorization.identity,
          authentication_event_id: authorization.authentication_event_id
        )
      end

      def raise_record_conflict!(error, connection)
        if error.record.is_a?(InvoiceSource) && error.record.errors.of_kind?(:external_account_id, :taken)
          raise TenantConflictError, tenant_conflict_message
        end

        if error.record.is_a?(ExternalIdentity) &&
            (error.record.errors.of_kind?(:subject, :taken) || error.record.errors.of_kind?(:provider, :taken))
          raise IdentityConflictError, "That Xero identity could not be linked to this PaymentReminder login."
        end

        raise error
      end

      def raise_conflict_error!(connection)
        if connection.present? && InvoiceSource.xero.where(
          external_account_id: connection["tenantId"]
        ).where.not(account_id: account.id).exists?
          raise TenantConflictError, tenant_conflict_message
        end

        raise IdentityConflictError, "That Xero identity could not be linked to this PaymentReminder login."
      end

      def connection_selection_message
        "Choose exactly one Xero organization when you approve access."
      end

      def tenant_conflict_message
        "That Xero organization is already connected to another account."
      end
  end
end
