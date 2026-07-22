class PlatformAdminAccess
  ENVIRONMENT_KEY = "PLATFORM_ADMIN_EMAIL_ADDRESSES"

  class << self
    def allowed?(identity, email_addresses: configured_email_addresses)
      identity.present? && email_addresses.include?(normalize(identity.email_address))
    end

    def configured_email_addresses(environment: ENV, credentials: Rails.application.credentials)
      normalize_all(
        environment[ENVIRONMENT_KEY],
        credentials.dig(:platform_admin, :email_addresses)
      )
    end

    private
      def normalize_all(*values)
        values.flatten.compact_blank
          .flat_map { |value| value.to_s.split(/[\s,]+/) }
          .filter_map { |value| normalize(value).presence }
          .uniq
          .freeze
      end

      def normalize(value)
        value.to_s.strip.downcase
      end
  end
end
