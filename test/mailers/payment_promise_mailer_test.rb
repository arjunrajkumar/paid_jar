require "test_helper"

class PaymentPromiseMailerTest < ActionMailer::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @customer = @invoice.customer

    @account.update!(invoice_reminder_from_name: "Accounts Team")
    @customer.additional_email_addresses.create!(email: "bookkeeper@example.com")
    @payment_promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: create_source_message,
      promised_on: Date.new(2026, 8, 3)
    )
  end

  test "sends one multipart payment promise follow-up to every customer address from the account" do
    mail = PaymentPromiseMailer.follow_up(@payment_promise)

    assert_emails 1 do
      mail.deliver_now
    end

    assert_equal [ "customer@example.com", "bookkeeper@example.com" ], mail.to
    assert_equal [ "billing@paymentreminder.example" ], mail.from
    assert_equal [ "Accounts Team" ], mail[:from].display_names
    assert_equal "Payment status: Invoice INV-001", mail.subject
    assert_equal "text/plain", mail.text_part.mime_type
    assert_equal "text/html", mail.html_part.mime_type

    assert_follow_up_copy(mail.text_part.body.to_s)
    assert_follow_up_copy(Nokogiri::HTML(mail.html_part.body.to_s).text)
  end

  test "includes the provider invoice link in both parts when available" do
    @invoice.stubs(:online_invoice_url).returns("https://example.com/invoices/123")

    mail = PaymentPromiseMailer.follow_up(@payment_promise)

    assert_match "View Invoice", mail.text_part.body.to_s
    assert_match "https://example.com/invoices/123", mail.text_part.body.to_s
    assert_match "View Invoice", mail.html_part.body.to_s
    assert_match "https://example.com/invoices/123", mail.html_part.body.to_s
  end

  private
    def create_source_message
      @invoice.conversation_messages.create!(
        account: @account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction: :inbound,
        kind: :customer_reply,
        status: :received,
        received_at: Time.current,
        provider_message_id: "payment-promise-mailer-source",
        from_address: "customer@example.com",
        to_addresses: [ "billing@paymentreminder.example" ],
        cc_addresses: [],
        subject: "Re: Invoice INV-001",
        body: "I will pay on August 3."
      )
    end

    def assert_follow_up_copy(body)
      assert_match "payment for invoice INV-001 would be made by August 03, 2026", body
      assert_match "still show this invoice as outstanding", body
      assert_match "Could you confirm the payment status?", body
      assert_match "Due date: July 31, 2026", body
      assert_match "Amount due: USD 125", body
      assert_match "Promised payment date: August 03, 2026", body
    end
end
