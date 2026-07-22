module EmailConnection::Errors
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class TemporaryDeliveryError < Error; end
  class AmbiguousDeliveryError < Error; end
  class PermanentDeliveryError < Error; end
end
