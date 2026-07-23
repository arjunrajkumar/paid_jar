require "google/apis/gmail_v1"
require "json"

class EmailConnection::Gmail::Mailbox
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
    ACCESS_TOKEN_SCOPE_INSUFFICIENT
  ].freeze

  def initialize(
    connection: nil,
    provider_account_id: connection&.provider_account_id,
    credential_generation: connection&.credential_generation,
    access_token: nil,
    service: Google::Apis::GmailV1::GmailService.new
  )
    @connection = connection
    @provider_account_id = provider_account_id.to_s.strip.presence
    @credential_generation = credential_generation&.to_i
    @candidate_access_token = access_token
    @service = service
  end

  def profile
    perform(:profile) { service.get_user_profile("me") }
  end

  def each_history_page(start_history_id:)
    return enum_for(__method__, start_history_id:) unless block_given?

    page_token = nil
    loop do
      response = perform(:history) do
        service.list_user_histories(
          "me",
          start_history_id: start_history_id.to_s,
          history_types: [ "messageAdded" ],
          page_token:
        )
      end
      yield response
      page_token = response.next_page_token
      break if page_token.blank?
    end
  end

  def each_message_since(time:)
    return enum_for(__method__, time:) unless block_given?

    page_token = nil
    loop do
      response = perform(:messages) do
        service.list_user_messages(
          "me",
          include_spam_trash: true,
          q: "after:#{time.to_i}",
          page_token:
        )
      end
      Array(response.messages).each { |message| yield message }
      page_token = response.next_page_token
      break if page_token.blank?
    end
  end

  def message(id:)
    perform(:message) do
      service.get_user_message("me", id.to_s, format: "full")
    end
  end

  private
    attr_reader :connection,
      :provider_account_id,
      :credential_generation,
      :candidate_access_token,
      :service

    def perform(operation)
      translate_oauth_failure { perform_request(operation) { yield } }
    end

    def with_pinned_connection
      unless connection
        @request_access_token = candidate_access_token
        service.authorization = @request_access_token
        return yield
      end

      connection.with_lock do
        connection.assert_gmail_credentials!(
          provider_account_id:,
          credential_generation:
        )
        @request_access_token = connection.access_token
        service.authorization = @request_access_token
        yield
      end
    end

    def perform_request(operation)
      attempts = 0
      begin
        prepare_authorization!
        with_pinned_connection { yield }
      rescue Google::Apis::AuthorizationError => error
        attempts += 1
        if attempts == 1 && connection.present?
          connection.refresh_gmail_access_token_if_needed!(
            force: true,
            provider_account_id:,
            credential_generation:
          )
          retry
        end

        mark_connection_errored!(error)
        raise EmailConnection::Errors::AuthenticationError,
          "gmail_authentication_failed",
          cause: nil
      rescue Google::Apis::RateLimitError,
        Google::Apis::RequestTimeOutError,
        Google::Apis::ServerError,
        Google::Apis::TransmissionError
        raise EmailConnection::Errors::TemporaryProviderError,
          "gmail_temporarily_unavailable",
          cause: nil
      rescue Google::Apis::ProjectNotLinkedError
        raise EmailConnection::Errors::PermanentProviderError,
          "gmail_request_rejected",
          cause: nil
      rescue Google::Apis::ClientError => error
        classify_client_error!(error, operation:)
      rescue Google::Apis::Error
        raise EmailConnection::Errors::PermanentProviderError,
          "gmail_request_rejected",
          cause: nil
      rescue Timeout::Error, SocketError, SystemCallError, IOError
        raise EmailConnection::Errors::TemporaryProviderError,
          "gmail_temporarily_unavailable",
          cause: nil
      end
    end

    def translate_oauth_failure
      yield
    rescue EmailConnection::Errors::TemporaryProviderError,
      EmailConnection::Errors::PermanentProviderError,
      EmailConnection::Errors::AuthenticationError,
      EmailConnection::Errors::CredentialChanged
      raise
    rescue EmailConnection::Errors::TemporaryDeliveryError
      raise EmailConnection::Errors::TemporaryProviderError,
        "gmail_temporarily_unavailable",
        cause: nil
    rescue EmailConnection::Errors::PermanentDeliveryError
      raise EmailConnection::Errors::PermanentProviderError,
        "gmail_request_rejected",
        cause: nil
    end

    def prepare_authorization!
      return unless connection

      connection.refresh_gmail_access_token_if_needed!(
        provider_account_id:,
        credential_generation:
      )
    end

    def classify_client_error!(error, operation:)
      reasons = gmail_error_reasons(error)
      status_code = gmail_error_status_code(error)
      status = gmail_error_status(error)

      if status_code == 404 && operation == :history
        raise EmailConnection::Errors::HistoryExpired,
          "gmail_history_expired",
          cause: nil
      elsif status_code == 404 && operation == :message
        raise EmailConnection::Errors::MessageNotFound,
          "gmail_message_not_found",
          cause: nil
      elsif status_code.in?([ 408, 429 ]) ||
          status_code >= 500 ||
          reasons.intersect?(RETRYABLE_REASONS) ||
          status.in?(%w[RESOURCE_EXHAUSTED UNAVAILABLE DEADLINE_EXCEEDED])
        raise EmailConnection::Errors::TemporaryProviderError,
          "gmail_temporarily_unavailable",
          cause: nil
      elsif status_code == 403 &&
          (reasons.intersect?(AUTHORIZATION_REASONS) ||
            status.in?(%w[PERMISSION_DENIED UNAUTHENTICATED]))
        mark_connection_errored!(error)
        raise EmailConnection::Errors::AuthorizationError,
          "gmail_authorization_failed",
          cause: nil
      end

      raise EmailConnection::Errors::PermanentProviderError,
        "gmail_request_rejected",
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

    def mark_connection_errored!(error)
      return unless connection
      return if connection.mark_errored!(
        error,
        provider_account_id:,
        credential_generation:,
        access_token: @request_access_token
      )

      if connection.gmail_credentials_current?(
        provider_account_id:,
        credential_generation:
      )
        raise EmailConnection::Errors::TemporaryProviderError,
          "gmail_credentials_changed",
          cause: nil
      end

      raise EmailConnection::Errors::CredentialChanged,
        "email_connection_credentials_changed",
        cause: nil
    end
end
