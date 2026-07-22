require "test_helper"

class ManualInvoiceReminderMailerTest < ActionMailer::TestCase
  test "builds a neutral manual reminder from the account Gmail address" do
    invoice = invoices(:xero_invoice)

    email = ManualInvoiceReminderMailer.reminder(invoice)

    assert_equal [ "customer@example.com" ], email.to
    assert_equal [ "billing@paymentreminder.example" ], email.from
    assert_equal "Payment reminder: Invoice INV-001", email.subject
    assert_match(/USD 125/, email.text_part.body.decoded)
    assert_match(/July 31, 2026/, email.text_part.body.decoded)
  end
end
