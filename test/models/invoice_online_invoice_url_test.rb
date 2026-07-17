require "test_helper"

class InvoiceOnlineInvoiceUrlTest < ActiveSupport::TestCase
  test "returns normalized customer-facing invoice artifacts" do
    invoice = Invoice.new(
      provider_data: {
        "online_invoice_url" => "https://example.com/invoice/123",
        "invoice_pdf_url" => "https://example.com/invoice/123.pdf"
      }
    )

    assert_equal "https://example.com/invoice/123", invoice.online_invoice_url
    assert_equal "https://example.com/invoice/123.pdf", invoice.invoice_pdf_url
  end

  test "returns no invoice artifacts when the provider did not supply them" do
    invoice = Invoice.new(provider_data: {})

    assert_nil invoice.online_invoice_url
    assert_nil invoice.invoice_pdf_url
  end
end
