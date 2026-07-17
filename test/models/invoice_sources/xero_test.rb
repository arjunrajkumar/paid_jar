require "test_helper"

module InvoiceSources
  class XeroTest < ActiveSupport::TestCase
    test "connect exchanges the code and stores the active tenant" do
      account = Account.create!(name: "New Xero Account")
      source = account.invoice_sources.build(provider: :xero)
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      source = InvoiceSources::Xero.new(source).connect!(code: "auth-code")

      assert_predicate source, :persisted?
      assert_predicate source, :active?
      assert_equal "access-token", source.access_token
      assert_equal "refresh-token", source.refresh_token
      assert_equal "tenant-123", source.external_account_id
      assert_equal "PaymentReminder Demo", source.external_account_name
      assert_equal "person@example.com", source.provider_data["email"]
      assert_equal "Bearer", source.raw_token_data["token_type"]
      refute source.raw_token_data.key?("access_token")
      refute source.raw_token_data.key?("refresh_token")
      refute source.raw_token_data.key?("id_token")
      assert fake_client.exchange_code_called
      assert fake_client.connections_called
      assert fake_client.userinfo_called
    end

    test "sync_invoices stores Xero invoices" do
      source = invoice_sources(:xero)
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      assert_difference -> { source.customers.count }, 1 do
        assert_difference -> { source.invoices.count }, 1 do
          InvoiceSources::Xero.new(source).sync_invoices!
        end
      end

      invoice = source.invoices.find_by!(external_id: "invoice-456")
      customer = source.customers.find_by!(external_id: "contact-456")
      assert_equal "INV-456", invoice.number
      assert_equal "Example Customer", invoice.contact_name
      assert_equal "AUTHORISED", invoice.provider_status
      assert_equal "open", invoice.status
      assert_equal BigDecimal("250.50"), invoice.total
      assert_equal Date.new(2026, 7, 11), invoice.paid_on
      assert_equal "https://in.xero.com/invoice-456", invoice.provider_data["online_invoice_url"]
      assert_equal customer, invoice.customer
      assert_equal "Example Customer", customer.name
      assert_equal "billing@example.com", customer.email
      assert_equal Date.new(2026, 7, 1), customer.details_observed_at.to_date
      assert fake_client.invoices_called
      assert_equal 1, fake_client.online_invoice_calls
    end

    test "sync_invoices reuses the Xero customer for the same contact" do
      source = invoice_sources(:xero)
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Xero.new(source).sync_invoices!

      assert_no_difference [ -> { source.customers.count }, -> { source.invoices.count } ] do
        InvoiceSources::Xero.new(source).sync_invoices!
      end

      assert_equal 1, fake_client.online_invoice_calls
    end

    test "sync_invoices does not request an online URL for an invoice that is not outstanding" do
      source = invoice_sources(:xero)
      fake_client = FakeXeroClient.new(status: "PAID", amount_due: "0.00")

      InvoiceSources::Xero::InvoiceSync.new(source, client: fake_client).sync!

      invoice = source.invoices.find_by!(external_id: "invoice-456")
      assert_predicate invoice, :status_paid?
      assert_nil invoice.online_invoice_url
      assert_equal 0, fake_client.online_invoice_calls
    end

    test "sync_invoices keeps syncing after online invoice enrichment fails" do
      source = invoice_sources(:xero)
      error = InvoiceSources::Xero::OauthClient::Error.new("rate limited")
      fake_client = FakeXeroClient.new(
        additional_invoice_count: 1,
        online_invoice_error: error
      )
      Rails.logger.expects(:warn).with(
        "xero.online_invoice_url_unavailable " \
          "invoice_source_id=#{source.id} invoice_id=invoice-456 error=rate limited"
      )

      InvoiceSources::Xero::InvoiceSync.new(source, client: fake_client).sync!

      assert source.invoices.exists?(external_id: "invoice-456")
      assert source.invoices.exists?(external_id: "invoice-extra-1")
      assert_equal 1, fake_client.online_invoice_calls
      assert_predicate source.reload, :active?
      assert_nil source.last_error
    end

    test "sync_invoices caps online invoice enrichment requests" do
      source = invoice_sources(:xero)
      enrichment_limit = InvoiceSources::Xero::InvoiceSync::ONLINE_INVOICE_ENRICHMENT_LIMIT
      fake_client = FakeXeroClient.new(additional_invoice_count: enrichment_limit)

      InvoiceSources::Xero::InvoiceSync.new(source, client: fake_client).sync!

      assert_equal enrichment_limit, fake_client.online_invoice_calls
      assert_predicate source.reload, :active?
      assert_nil source.invoices.find_by!(external_id: "invoice-extra-#{enrichment_limit}").online_invoice_url
    end

    test "sync_invoices uses an invoice identity when Xero omits the contact id" do
      source = invoice_sources(:xero)
      fake_client = FakeXeroClient.new(contact_id: nil)

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Xero.new(source).sync_invoices!

      invoice = source.invoices.find_by!(external_id: "invoice-456")
      assert_equal "invoice:invoice-456", invoice.customer.external_id
      assert_equal "Example Customer", invoice.customer.name
      assert_equal "billing@example.com", invoice.customer.email
      assert_nil invoice.contact_external_id
    end

    test "sync_invoices requests and stores only accounts receivable invoices" do
      source = invoice_sources(:xero)
      fake_client = FakeXeroClient.new(include_payable_invoice: true)

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      assert_difference -> { source.invoices.count }, 1 do
        InvoiceSources::Xero.new(source).sync_invoices!
      end

      assert_equal 'Type=="ACCREC"', fake_client.invoices_filter
      assert source.invoices.exists?(external_id: "invoice-456")
      assert_not source.invoices.exists?(external_id: "bill-456")
    end

    test "sync_invoice ignores an accounts payable bill" do
      source = invoice_sources(:xero)
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      assert_no_difference -> { source.invoices.count } do
        InvoiceSources::Xero.new(source).sync_invoice!(external_id: "bill-456")
      end

      assert_not source.invoices.exists?(external_id: "bill-456")
    end

    test "refreshes an expired access token before syncing invoices" do
      source = invoice_sources(:xero)
      source.update!(access_token: "old-token", refresh_token: "old-refresh-token", expires_at: 1.minute.ago)
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Xero.new(source).sync_invoices!

      assert_equal "new-access-token", source.reload.access_token
      assert_equal "new-refresh-token", source.refresh_token
      refute source.raw_token_data.key?("access_token")
      refute source.raw_token_data.key?("refresh_token")
      assert fake_client.refresh_token_called
    end

    class FakeXeroClient
      attr_accessor :exchange_code_called, :connections_called, :userinfo_called,
        :invoices_called, :invoices_filter, :refresh_token_called, :online_invoice_calls

      def initialize(
        tenant_id: "tenant-123",
        tenant_name: "PaymentReminder Demo",
        include_payable_invoice: false,
        additional_invoice_count: 0,
        contact_id: "contact-456",
        status: "AUTHORISED",
        amount_due: "250.50",
        online_invoice_error: nil
      )
        @tenant_id = tenant_id
        @tenant_name = tenant_name
        @include_payable_invoice = include_payable_invoice
        @additional_invoice_count = additional_invoice_count
        @contact_id = contact_id
        @status = status
        @amount_due = amount_due
        @online_invoice_error = online_invoice_error
        @online_invoice_calls = 0
      end

      def exchange_code(code:)
        raise "unexpected code" unless code == "auth-code"

        self.exchange_code_called = true
        {
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "id_token" => "id-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
        }
      end

      def refresh_token(refresh_token:)
        raise "unexpected refresh token" unless refresh_token == "old-refresh-token"

        self.refresh_token_called = true
        {
          "access_token" => "new-access-token",
          "refresh_token" => "new-refresh-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
        }
      end

      def connections(access_token:)
        raise "unexpected access token" unless access_token == "access-token"

        self.connections_called = true
        [
          {
            "tenantId" => @tenant_id,
            "tenantName" => @tenant_name
          }
        ]
      end

      def userinfo(access_token:)
        raise "unexpected access token" unless access_token == "access-token"

        self.userinfo_called = true
        {
          "xero_userid" => "user-123",
          "email" => "person@example.com"
        }
      end

      def invoices(access_token:, tenant_id:, where:)
        raise "unexpected access token" unless access_token.in?(%w[access-token new-access-token])
        raise "unexpected tenant id" unless tenant_id == "xero-tenant-123"

        self.invoices_called = true
        self.invoices_filter = where
        invoice = {
          "InvoiceID" => "invoice-456",
          "InvoiceNumber" => "INV-456",
          "Type" => "ACCREC",
          "Status" => @status,
          "CurrencyCode" => "USD",
          "AmountDue" => @amount_due,
          "AmountPaid" => "0.00",
          "Total" => "250.50",
          "DateString" => "2026-07-01",
          "DueDateString" => "2026-07-31",
          "FullyPaidOnDate" => "/Date(1783728000000+0000)/",
          "Contact" => {
            "ContactID" => @contact_id,
            "Name" => "Example Customer",
            "EmailAddress" => "billing@example.com"
          }
        }
        invoices = [ invoice ]
        1.upto(@additional_invoice_count) do |index|
          invoices << invoice.merge(
            "InvoiceID" => "invoice-extra-#{index}",
            "InvoiceNumber" => "INV-EXTRA-#{index}"
          )
        end
        if @include_payable_invoice
          invoices << {
            "InvoiceID" => "bill-456",
            "InvoiceNumber" => "BILL-456",
            "Type" => "ACCPAY",
            "Status" => "AUTHORISED",
            "CurrencyCode" => "USD",
            "AmountDue" => "100.00",
            "AmountPaid" => "0.00",
            "Total" => "100.00"
          }
        end

        { "Invoices" => invoices }
      end

      def invoice(access_token:, tenant_id:, invoice_id:)
        raise "unexpected access token" unless access_token == "access-token"
        raise "unexpected tenant id" unless tenant_id == "xero-tenant-123"
        raise "unexpected invoice id" unless invoice_id == "bill-456"

        {
          "Invoices" => [
            {
              "InvoiceID" => "bill-456",
              "InvoiceNumber" => "BILL-456",
              "Type" => "ACCPAY",
              "Status" => "AUTHORISED",
              "CurrencyCode" => "USD",
              "AmountDue" => "100.00",
              "AmountPaid" => "0.00",
              "Total" => "100.00"
            }
          ]
        }
      end

      def online_invoice(access_token:, tenant_id:, invoice_id:)
        raise "unexpected access token" unless access_token.in?(%w[access-token new-access-token])
        raise "unexpected tenant id" unless tenant_id == "xero-tenant-123"
        self.online_invoice_calls += 1
        raise @online_invoice_error if @online_invoice_error
        raise "unexpected invoice id" unless invoice_id.start_with?("invoice-")

        {
          "OnlineInvoices" => [
            { "OnlineInvoiceUrl" => "https://in.xero.com/#{invoice_id}" }
          ]
        }
      end
    end
  end
end
