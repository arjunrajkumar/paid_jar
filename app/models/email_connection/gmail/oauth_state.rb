class EmailConnection::Gmail::OauthState
  PURPOSE = "outbound_email_gmail_oauth"
  EXPIRES_IN = 15.minutes

  class << self
    def issue(account:, nonce:)
      verifier.generate(
        { "account_id" => account.id, "nonce" => nonce },
        expires_in: EXPIRES_IN,
        purpose: PURPOSE
      )
    end

    def valid?(token, account:, nonce:)
      account_id(token, nonce:) == account.id
    end

    def account_id(token, nonce:)
      payload = verifier.verify(token, purpose: PURPOSE)
      return unless ActiveSupport::SecurityUtils.secure_compare(
        payload.fetch("nonce").to_s,
        nonce.to_s
      )

      Integer(payload.fetch("account_id"))
    rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, ArgumentError, TypeError
      nil
    end

    private
      def verifier
        Rails.application.message_verifier(:outbound_email_oauth)
      end
  end
end
