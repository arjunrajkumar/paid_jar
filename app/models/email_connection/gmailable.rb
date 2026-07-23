module EmailConnection::Gmailable
  extend ActiveSupport::Concern

  EMAIL_SCOPE = "https://www.googleapis.com/auth/userinfo.email"
  PROFILE_SCOPE = "https://www.googleapis.com/auth/userinfo.profile"
  SEND_SCOPE = "https://www.googleapis.com/auth/gmail.send"
  READ_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
  REQUIRED_SCOPES = [ EMAIL_SCOPE, PROFILE_SCOPE, SEND_SCOPE, READ_SCOPE ].freeze
  SCOPE_ALIASES = {
    "email" => EMAIL_SCOPE,
    EMAIL_SCOPE => EMAIL_SCOPE,
    "profile" => PROFILE_SCOPE,
    PROFILE_SCOPE => PROFILE_SCOPE
  }.freeze
  TOKEN_REFRESH_BUFFER = 5.minutes

  class << self
    def normalize_scopes(scopes)
      Array(scopes)
        .flat_map { |scope| scope.to_s.split }
        .filter_map { |scope| SCOPE_ALIASES.fetch(scope, scope).presence }
        .uniq
    end

    def required_scopes_granted?(scopes)
      (REQUIRED_SCOPES - normalize_scopes(scopes)).empty?
    end
  end

  included do
    normalizes :provider_account_id, with: ->(value) { value.to_s.strip.presence }
    normalizes :scopes, with: ->(value) { EmailConnection::Gmailable.normalize_scopes(value) }
    validates :provider_account_id, presence: true, if: :active_gmail_connection?
    validate :gmail_required_scopes_granted, if: :active_gmail_connection?
  end

  def connect_gmail!(
    email:,
    name:,
    provider_account_id:,
    history_id:,
    access_token:,
    refresh_token:,
    expires_at:,
    scopes:
  )
    normalized_scopes = EmailConnection::Gmailable.normalize_scopes(scopes)
    normalized_provider_account_id = provider_account_id.to_s.strip

    transaction do
      lock! if persisted?
      identity_unchanged = self.provider_account_id.present? &&
        self.provider_account_id == normalized_provider_account_id
      preserve_sync_state = identity_unchanged && inbound_cursor.present?
      existing_refresh_token = refresh_token() if identity_unchanged && !errored?
      replacement_refresh_token = refresh_token.presence || existing_refresh_token
      if replacement_refresh_token.blank? && identity_unchanged && errored?
        raise EmailConnection::Errors::AuthenticationError,
          "Google did not issue a usable refresh token.",
          cause: nil
      end
      existing_cursor = inbound_cursor if preserve_sync_state
      existing_last_attempted_at = last_inbound_attempted_at if preserve_sync_state
      existing_last_synced_at = last_inbound_synced_at if preserve_sync_state

      assign_attributes(
        provider: :gmail,
        provider_account_id: normalized_provider_account_id,
        connected_email: email,
        provider_display_name: name,
        access_token:,
        refresh_token: replacement_refresh_token,
        token_expires_at: expires_at,
        scopes: normalized_scopes,
        status: :active,
        inbound_cursor: existing_cursor.presence || history_id.to_s,
        inbound_enabled_at: identity_unchanged ? (inbound_enabled_at.presence || Time.current) : Time.current,
        last_inbound_attempted_at: existing_last_attempted_at,
        last_inbound_synced_at: existing_last_synced_at,
        last_inbound_error: nil,
        last_error: nil,
        credential_generation: credential_generation.to_i + 1,
        inbound_sync_job_id: nil,
        inbound_sync_enqueued_at: nil
      )
      save!
      reconcile_replaced_credentials_receipts!
      account.update!(
        invoice_reminder_from_email: connected_email,
        invoice_reminder_from_name: account.invoice_reminder_from_name.presence || account.name
      )
    end

    self
  end

  def gmail_send_scope_granted?
    scopes.include?(SEND_SCOPE)
  end

  def gmail_read_scope_granted?
    scopes.include?(READ_SCOPE)
  end

  def inbound_ready?
    gmail_ready?
  end

  def gmail_ready?
    active_gmail_connection? &&
      provider_account_id.present? &&
      EmailConnection::Gmailable.required_scopes_granted?(scopes) &&
      access_token.present? &&
      refresh_token.present? &&
      connected_email.present?
  end

  def refresh_gmail_access_token_if_needed!(
    oauth_client: EmailConnection::Gmail::OauthClient.new,
    force: false,
    provider_account_id: self.provider_account_id,
    credential_generation: self.credential_generation
  )
    expected_provider_account_id = provider_account_id.to_s.strip
    expected_credential_generation = credential_generation.to_i
    refresh_token_value = nil
    current_access_token = nil
    refresh_needed = false

    with_lock do
      assert_gmail_credentials!(
        provider_account_id: expected_provider_account_id,
        credential_generation: expected_credential_generation
      )
      current_access_token = access_token
      refresh_needed = force || gmail_token_refresh_needed?
      refresh_token_value = refresh_token if refresh_needed
    end
    return current_access_token unless refresh_needed

    token_data = oauth_client.refresh_token(refresh_token: refresh_token_value)
    with_lock do
      assert_gmail_credentials!(
        provider_account_id: expected_provider_account_id,
        credential_generation: expected_credential_generation
      )
      if access_token != current_access_token || refresh_token != refresh_token_value
        return access_token
      end

      update!(
        access_token: token_data.fetch("access_token"),
        refresh_token: token_data["refresh_token"].presence || refresh_token,
        token_expires_at: Time.current + token_data.fetch("expires_in").to_i.seconds,
        scopes: token_data["scope"].presence || scopes,
        last_error: nil
      )
      current_access_token = access_token
    end
    current_access_token
  rescue EmailConnection::Errors::CredentialChanged
    raise
  rescue EmailConnection::Errors::AuthenticationError => error
    marked = mark_errored!(
      error,
      provider_account_id: expected_provider_account_id,
      credential_generation: expected_credential_generation,
      access_token: current_access_token,
      refresh_token: refresh_token_value
    )
    unless marked
      if token = access_token_after_superseded_refresh(
        provider_account_id: expected_provider_account_id,
        credential_generation: expected_credential_generation,
        access_token: current_access_token,
        refresh_token: refresh_token_value
      )
        return token
      end

      raise EmailConnection::Errors::CredentialChanged,
        "email_connection_credentials_changed",
        cause: nil
    end
    raise
  rescue EmailConnection::Errors::TemporaryDeliveryError,
    EmailConnection::Errors::PermanentDeliveryError
    if token = access_token_after_superseded_refresh(
      provider_account_id: expected_provider_account_id,
      credential_generation: expected_credential_generation,
      access_token: current_access_token,
      refresh_token: refresh_token_value
    )
      return token
    end

    assert_gmail_credentials_current!(
      provider_account_id: expected_provider_account_id,
      credential_generation: expected_credential_generation
    )
    raise
  end

  def gmail_credentials_current?(provider_account_id:, credential_generation:)
    self.class.where(
      id:,
      provider: EmailConnection.providers.fetch(:gmail),
      status: EmailConnection.statuses.fetch(:active),
      provider_account_id: provider_account_id.to_s.strip,
      credential_generation: credential_generation.to_i
    ).exists?
  end

  def assert_gmail_credentials_current!(provider_account_id:, credential_generation:)
    return true if gmail_credentials_current?(provider_account_id:, credential_generation:)

    raise EmailConnection::Errors::CredentialChanged,
      "email_connection_credentials_changed",
      cause: nil
  end

  def assert_gmail_credentials!(provider_account_id:, credential_generation:)
    current = active_gmail_connection? &&
      self.provider_account_id == provider_account_id.to_s.strip &&
      self.credential_generation == credential_generation.to_i
    return true if current

    raise EmailConnection::Errors::CredentialChanged,
      "email_connection_credentials_changed",
      cause: nil
  end

  private
    def active_gmail_connection?
      gmail? && active?
    end

    def gmail_token_refresh_needed?
      token_expires_at.blank? || token_expires_at <= TOKEN_REFRESH_BUFFER.from_now
    end

    def gmail_required_scopes_granted
      return if EmailConnection::Gmailable.required_scopes_granted?(scopes)

      errors.add(:scopes, "must include Gmail send and readonly access")
    end

    def access_token_after_superseded_refresh(
      provider_account_id:,
      credential_generation:,
      access_token:,
      refresh_token:
    )
      with_lock do
        assert_gmail_credentials!(
          provider_account_id:,
          credential_generation:
        )
        if self.access_token != access_token || self.refresh_token != refresh_token
          return self.access_token
        end
      end

      nil
    end

    def reconcile_replaced_credentials_receipts!
      email_message_receipts
        .where(status: %i[pending processing failed])
        .where.not(email_connection_generation: credential_generation)
        .find_each do |receipt|
          if receipt.provider_account_id == provider_account_id
            receipt.rebind_unprocessed_to_generation!(generation: credential_generation)
          else
            receipt.retire_unprocessed!(reason: :mailbox_replaced)
          end
        end
    end
end
