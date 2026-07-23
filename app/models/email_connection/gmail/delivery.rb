require "google/apis/gmail_v1"
require "json"

class EmailConnection::Gmail::Delivery
  RETRYABLE_REASONS = %w[
    rateLimitExceeded
    userRateLimitExceeded
    quotaExceeded
    backendError
    RESOURCE_EXHAUSTED
    UNAVAILABLE
    DEADLINE_EXCEEDED
  ].freeze
  AUTHORIZATION_REASONS = %w[
    authError
    insufficientPermissions
    domainPolicy
    forbidden
    PERMISSION_DENIED
    UNAUTHENTICATED
  ].freeze

  def initialize(
    account:,
    connection:,
    provider_account_id:,
    credential_generation:,
    service: Google::Apis::GmailV1::GmailService.new
  )
    @account = account
    @connection = connection
    @provider_account_id = provider_account_id.to_s.strip
    @credential_generation = credential_generation.to_i
    @service = service
  end

  def deliver(mail_message)
    validate_current_connection!
    connection.refresh_gmail_access_token_if_needed!(
      provider_account_id:,
      credential_generation:
    )
    response = send_with_one_authorization_refresh(mail_message)
    EmailConnection::Delivery::Result.new(
      provider_message_id: response.id,
      provider_thread_id: response.thread_id
    )
  rescue Google::Apis::RateLimitError => error
    raise EmailConnection::Errors::TemporaryDeliveryError,
      "Gmail is temporarily unavailable.",
      cause: nil
  rescue Google::Apis::RequestTimeOutError,
    Google::Apis::ServerError,
    Google::Apis::TransmissionError => error
    raise EmailConnection::Errors::AmbiguousDeliveryError,
      "Gmail delivery outcome is unknown.",
      cause: nil
  rescue Google::Apis::ProjectNotLinkedError
    raise EmailConnection::Errors::PermanentDeliveryError,
      "Gmail rejected the request.",
      cause: nil
  rescue Google::Apis::ClientError => error
    classify_client_error!(error)
  rescue Google::Apis::Error
    raise EmailConnection::Errors::PermanentDeliveryError,
      "Gmail rejected the request.",
      cause: nil
  rescue Timeout::Error, SocketError, SystemCallError, IOError
    raise EmailConnection::Errors::AmbiguousDeliveryError,
      "Gmail delivery outcome is unknown.",
      cause: nil
  end

  private
    attr_reader :account,
      :connection,
      :provider_account_id,
      :credential_generation,
      :service

    def validate_current_connection!
      connection.with_lock do
        connection.assert_gmail_credentials!(
          provider_account_id:,
          credential_generation:
        )
        validate_connection!
      end
    end

    def validate_connection!
      unless connection.account_id == account.id && connection.gmail_ready?
        raise EmailConnection::Errors::PermanentDeliveryError, "Email connection is not active for this account."
      end

      unless connection.sender_matches?(account.invoice_reminder_from_email)
        raise EmailConnection::Errors::PermanentDeliveryError, "Sender address does not match the connected Gmail account."
      end
    end

    def apply_sender!(mail_message)
      sender_name = account.invoice_reminder_from_name.presence || account.name
      mail_message[:from] = Mail::Address.new(connection.connected_email).tap do |address|
        address.display_name = sender_name
      end.to_s
    end

    def send_with_one_authorization_refresh(mail_message)
      attempts = 0

      begin
        send_message(mail_message)
      rescue Google::Apis::AuthorizationError => error
        attempts += 1
        if attempts == 1
          connection.refresh_gmail_access_token_if_needed!(
            force: true,
            provider_account_id:,
            credential_generation:
          )
          retry
        end

        raise_authentication_failure!(error)
      end
    end

    def send_message(mail_message)
      connection.with_lock do
        connection.assert_gmail_credentials!(
          provider_account_id:,
          credential_generation:
        )
        validate_connection!
        apply_sender!(mail_message)
        @request_access_token = connection.access_token
        service.authorization = @request_access_token
        service.send_user_message(
          "me",
          Google::Apis::GmailV1::Message.new(raw: mail_message.encoded)
        )
      end
    end

    def classify_client_error!(error)
      reasons = gmail_error_reasons(error)
      status = gmail_error_status(error)

      if gmail_error_status_code(error) == 429 ||
          gmail_error_status_code(error) >= 500 ||
          reasons.intersect?(RETRYABLE_REASONS) ||
          status.in?(%w[RESOURCE_EXHAUSTED UNAVAILABLE DEADLINE_EXCEEDED])
        raise EmailConnection::Errors::TemporaryDeliveryError,
          "Gmail is temporarily unavailable.",
          cause: nil
      end

      if gmail_error_status_code(error) == 403 &&
          (reasons.intersect?(AUTHORIZATION_REASONS) ||
            status.in?(%w[PERMISSION_DENIED UNAUTHENTICATED]))
        raise_authentication_failure!(error)
      end

      raise EmailConnection::Errors::PermanentDeliveryError,
        "Gmail rejected the request.",
        cause: nil
    end

    def gmail_error_reasons(error)
      payload = gmail_error_payload(error)
      legacy_reasons = Array(payload.dig("error", "errors")).filter_map { |item| item["reason"] }
      payload_details = Array(payload.dig("error", "details")).filter_map { |item| item["reason"] }
      object_details = if error.respond_to?(:details)
        Array(error.details).filter_map do |item|
          item.respond_to?(:reason) ? item.reason : item.try(:[], "reason")
        end
      else
        []
      end

      (legacy_reasons + payload_details + object_details).map(&:to_s).uniq
    end

    def gmail_error_status(error)
      object_status = error.status if error.respond_to?(:status)
      object_status.presence || gmail_error_payload(error).dig("error", "status").to_s.presence
    end

    def gmail_error_status_code(error)
      error.status_code.to_i
    end

    def gmail_error_payload(error)
      JSON.parse(error.body.presence || "{}")
    rescue JSON::ParserError
      {}
    end

    def raise_authentication_failure!(error)
      marked = connection.mark_errored!(
        error,
        provider_account_id:,
        credential_generation:,
        access_token: @request_access_token
      )
      if marked
        raise EmailConnection::Errors::AuthenticationError,
          "Gmail authentication failed.",
          cause: nil
      end

      if connection.gmail_credentials_current?(
        provider_account_id:,
        credential_generation:
      )
        raise EmailConnection::Errors::TemporaryDeliveryError,
          "Gmail credentials changed; retry delivery.",
          cause: nil
      end

      raise EmailConnection::Errors::CredentialChanged,
        "email_connection_credentials_changed",
        cause: nil
    end
end
