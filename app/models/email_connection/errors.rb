module EmailConnection::Errors
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class TemporaryDeliveryError < Error; end
  class AmbiguousDeliveryError < Error; end
  class PermanentDeliveryError < Error; end
  class TemporaryProviderError < TemporaryDeliveryError; end
  class PermanentProviderError < PermanentDeliveryError; end
  class AuthorizationError < AuthenticationError; end
  class CredentialChanged < PermanentDeliveryError; end
  class HistoryExpired < PermanentProviderError; end
  class MessageNotFound < PermanentProviderError; end
end
