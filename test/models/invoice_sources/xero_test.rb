require "test_helper"

module InvoiceSources
  class XeroTest < ActiveSupport::TestCase
    test "connect_from_authorization stores the verified identity and selected tenant" do
      account = Account.create!(name: "New Xero Account")
      source = account.invoice_sources.build(provider: :xero)
      identity = Struct.new(:subject, :email).new("verified-user-123", "person@example.com")
      token_set = {
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "id_token" => "id-token",
        "token_type" => "Bearer",
        "expires_in" => 1800,
        "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
      }
      connection = {
        "id" => "connection-123",
        "tenantId" => "tenant-123",
        "tenantName" => "PaymentReminder Demo"
      }

      source = InvoiceSources::Xero.new(source).connect_from_authorization!(
        token_set:,
        connection:,
        identity:,
        authentication_event_id: "auth-event-123"
      )

      assert_predicate source, :persisted?
      assert_predicate source, :active?
      assert_equal "access-token", source.access_token
      assert_equal "refresh-token", source.refresh_token
      assert_equal "tenant-123", source.external_account_id
      assert_equal "PaymentReminder Demo", source.external_account_name
      assert_equal "person@example.com", source.provider_data["email"]
      assert_equal "verified-user-123", source.provider_data["xero_user_id"]
      assert_equal "connection-123", source.provider_data["connection_id"]
      assert_equal "auth-event-123", source.provider_data["authentication_event_id"]
      assert_equal "Bearer", source.raw_token_data["token_type"]
      refute source.raw_token_data.key?("access_token")
      refute source.raw_token_data.key?("refresh_token")
      refute source.raw_token_data.key?("id_token")
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

    test "disconnect removes the remote connection before clearing local tokens" do
      source = invoice_sources(:xero)
      expires_at = source.expires_at
      source.update!(
        provider_data: source.provider_data.merge(
          "connection_id" => "connection-123",
          "authentication_event_id" => "auth-event-123"
        ),
        raw_token_data: { "token_type" => "Bearer", "scope" => "accounting.invoices.read" },
        last_error: "old error"
      )
      original_provider_data = source.provider_data.deep_dup
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Xero.new(source).disconnect!

      source.reload
      assert_predicate source, :disconnected?
      assert_nil source.access_token
      assert_nil source.refresh_token
      assert_nil source.expires_at
      assert_empty source.raw_token_data
      assert_nil source.last_error
      assert_equal "xero-tenant-123", source.external_account_id
      assert_equal "PaymentReminder Xero", source.external_account_name
      assert_equal original_provider_data, source.provider_data
      assert_equal "access-token", fake_client.disconnect_access_token
      assert_equal "connection-123", fake_client.disconnect_connection_id
      assert fake_client.disconnect_connection_called
      assert expires_at.present?
    end

    test "disconnect preserves credentials and tenant metadata when Xero rejects the request" do
      source = invoice_sources(:xero)
      source.update!(
        provider_data: source.provider_data.merge("connection_id" => "connection-123"),
        raw_token_data: { "token_type" => "Bearer" }
      )
      original_attributes = source.attributes.slice(
        "access_token",
        "refresh_token",
        "expires_at",
        "external_account_id",
        "external_account_name",
        "provider_data",
        "raw_token_data"
      )
      error = InvoiceSources::Xero::OauthClient::Error.new("Connection could not be deleted")
      fake_client = FakeXeroClient.new(disconnect_error: error)

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      raised_error = assert_raises InvoiceSources::Xero::OauthClient::Error do
        InvoiceSources::Xero.new(source).disconnect!
      end

      assert_same error, raised_error
      source.reload
      assert_predicate source, :error?
      assert_equal "Connection could not be deleted", source.last_error
      original_attributes.each do |attribute, value|
        assert_equal value, source.public_send(attribute), "expected #{attribute} to be preserved"
      end
    end

    test "disconnect refreshes an expired token before deleting the remote connection" do
      source = invoice_sources(:xero)
      source.update!(
        access_token: "old-token",
        refresh_token: "old-refresh-token",
        expires_at: 1.minute.ago,
        provider_data: source.provider_data.merge("connection_id" => "connection-123")
      )
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Xero.new(source).disconnect!

      assert fake_client.refresh_token_called
      assert_equal "new-access-token", fake_client.disconnect_access_token
      assert_equal "connection-123", fake_client.disconnect_connection_id
      assert_predicate source.reload, :disconnected?
      assert_nil source.access_token
      assert_nil source.refresh_token
    end

    test "disconnect resolves a legacy connection id for the source tenant" do
      source = invoice_sources(:xero)
      source.update!(
        provider_data: source.provider_data.except("connection_id").merge(
          "connections" => [
            {
              "id" => "wrong-connection",
              "tenantId" => "another-tenant",
              "tenantName" => "Another tenant"
            },
            {
              "id" => "legacy-connection-123",
              "tenantId" => source.external_account_id,
              "tenantName" => source.external_account_name
            }
          ]
        )
      )
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Xero.new(source).disconnect!

      assert_equal "legacy-connection-123", fake_client.disconnect_connection_id
      assert_predicate source.reload, :disconnected?
    end

    test "disconnect reports a missing connection id without clearing credentials" do
      source = invoice_sources(:xero)
      source.update!(
        provider_data: source.provider_data.except("connection_id").merge("connections" => []),
        raw_token_data: { "token_type" => "Bearer" }
      )
      original_access_token = source.access_token
      original_refresh_token = source.refresh_token
      original_provider_data = source.provider_data.deep_dup
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      error = assert_raises InvoiceSources::Xero::DisconnectError do
        InvoiceSources::Xero.new(source).disconnect!
      end

      assert_equal "Xero connection ID is missing.", error.message
      source.reload
      assert_predicate source, :error?
      assert_equal error.message, source.last_error
      assert_equal original_access_token, source.access_token
      assert_equal original_refresh_token, source.refresh_token
      assert_equal original_provider_data, source.provider_data
      assert_equal({ "token_type" => "Bearer" }, source.raw_token_data)
      assert_not fake_client.disconnect_connection_called
      assert_not fake_client.refresh_token_called
    end

    test "disconnect preserves credentials when refreshing an expired token fails" do
      source = invoice_sources(:xero)
      source.update!(
        access_token: "old-token",
        refresh_token: "old-refresh-token",
        expires_at: 1.minute.ago,
        provider_data: source.provider_data.merge("connection_id" => "connection-123"),
        raw_token_data: { "token_type" => "Bearer" }
      )
      error = InvoiceSources::Xero::OauthClient::Error.new("Refresh token was rejected")
      fake_client = FakeXeroClient.new(refresh_token_error: error)

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      raised_error = assert_raises InvoiceSources::Xero::OauthClient::Error do
        InvoiceSources::Xero.new(source).disconnect!
      end

      assert_same error, raised_error
      source.reload
      assert_predicate source, :error?
      assert_equal "Refresh token was rejected", source.last_error
      assert_equal "old-token", source.access_token
      assert_equal "old-refresh-token", source.refresh_token
      assert_equal({ "token_type" => "Bearer" }, source.raw_token_data)
      assert_not fake_client.disconnect_connection_called
    end

    class FakeXeroClient
      attr_accessor :invoices_called, :invoices_filter, :refresh_token_called,
        :online_invoice_calls, :disconnect_connection_called, :disconnect_access_token,
        :disconnect_connection_id

      def initialize(
        tenant_id: "tenant-123",
        tenant_name: "PaymentReminder Demo",
        include_payable_invoice: false,
        additional_invoice_count: 0,
        contact_id: "contact-456",
        status: "AUTHORISED",
        amount_due: "250.50",
        online_invoice_error: nil,
        disconnect_error: nil,
        refresh_token_error: nil
      )
        @tenant_id = tenant_id
        @tenant_name = tenant_name
        @include_payable_invoice = include_payable_invoice
        @additional_invoice_count = additional_invoice_count
        @contact_id = contact_id
        @status = status
        @amount_due = amount_due
        @online_invoice_error = online_invoice_error
        @disconnect_error = disconnect_error
        @refresh_token_error = refresh_token_error
        @online_invoice_calls = 0
      end

      def refresh_token(refresh_token:)
        raise "unexpected refresh token" unless refresh_token == "old-refresh-token"

        self.refresh_token_called = true
        raise @refresh_token_error if @refresh_token_error

        {
          "access_token" => "new-access-token",
          "refresh_token" => "new-refresh-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
        }
      end

      def disconnect_connection(access_token:, connection_id:)
        self.disconnect_connection_called = true
        self.disconnect_access_token = access_token
        self.disconnect_connection_id = connection_id
        raise @disconnect_error if @disconnect_error

        {}
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
