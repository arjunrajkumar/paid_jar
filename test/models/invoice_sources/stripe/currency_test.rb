require "test_helper"

module InvoiceSources
  class Stripe
    class CurrencyTest < ActiveSupport::TestCase
      test "keeps zero-decimal currency amounts in whole units" do
        Currency::ZERO_DECIMAL_CODES.each do |currency|
          assert_equal BigDecimal("123"), Currency.amount_from_minor_units(123, currency:)
        end
      end

      test "converts other currency amounts from two decimal minor units" do
        assert_equal BigDecimal("123.45"), Currency.amount_from_minor_units(12_345, currency: "usd")
        assert_equal BigDecimal("123.45"), Currency.amount_from_minor_units(12_345, currency: "TWD")
      end

      test "preserves missing amounts" do
        assert_nil Currency.amount_from_minor_units(nil, currency: "usd")
      end

      test "invoice sync uses the invoice currency when converting every amount" do
        source = accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_currency"
        )

        InvoiceSync.new(source, client: CurrencyInvoiceClient.new).sync!

        jpy_invoice = source.invoices.find_by!(external_id: "in_jpy")
        assert_equal BigDecimal("25050"), jpy_invoice.amount_due
        assert_equal BigDecimal("12525"), jpy_invoice.amount_paid
        assert_equal BigDecimal("25050"), jpy_invoice.total

        usd_invoice = source.invoices.find_by!(external_id: "in_usd")
        assert_equal BigDecimal("250.50"), usd_invoice.amount_due
        assert_equal BigDecimal("125.25"), usd_invoice.amount_paid
        assert_equal BigDecimal("250.50"), usd_invoice.total
      end

      class CurrencyInvoiceClient
        def invoices(stripe_account_id:)
          raise "unexpected account" unless stripe_account_id == "acct_currency"

          {
            "data" => [
              invoice_payload(id: "in_jpy", customer_id: "cus_jpy", currency: "jpy"),
              invoice_payload(id: "in_usd", customer_id: "cus_usd", currency: "usd")
            ]
          }
        end

        private
          def invoice_payload(id:, customer_id:, currency:)
            {
              "id" => id,
              "number" => id.upcase,
              "status" => "open",
              "currency" => currency,
              "amount_due" => 25_050,
              "amount_paid" => 12_525,
              "amount_remaining" => 25_050,
              "total" => 25_050,
              "created" => Time.zone.local(2026, 7, 1).to_i,
              "due_date" => Time.zone.local(2026, 7, 31).to_i,
              "customer" => customer_id,
              "customer_name" => "Currency Customer",
              "customer_email" => "currency@example.com"
            }
          end
      end
    end
  end
end
