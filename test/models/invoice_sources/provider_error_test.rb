require "test_helper"

class InvoiceSources::ProviderErrorTest < ActiveSupport::TestCase
  test "provider API errors share the retryable invoice source error type" do
    assert_operator InvoiceSources::Stripe::ApiClient::Error, :<, InvoiceSources::ProviderError
    assert_operator InvoiceSources::Xero::OauthClient::Error, :<, InvoiceSources::ProviderError
  end
end
