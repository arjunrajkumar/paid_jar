module InvoiceSources
  class Xero
    class InvoiceSync
      SALES_INVOICE_FILTER = 'Type=="ACCREC"'.freeze
      ONLINE_INVOICE_ENRICHMENT_LIMIT = 20

      def initialize(source, client: OauthClient.new)
        @source = source
        @client = client
      end

      def sync!
        payload = client.invoices(
          access_token: source.access_token,
          tenant_id: source.external_account_id,
          where: SALES_INVOICE_FILTER
        )

        Array(payload.fetch("Invoices", [])).each do |invoice_payload|
          sync_invoice!(invoice_payload)
        end

        source.update!(status: :active, last_synced_at: Time.current, last_error: nil)
      rescue OauthClient::Error => error
        source.update!(status: :error, last_error: error.message)
        raise
      end

      def sync_invoice_by_id!(external_id)
        payload = client.invoice(
          access_token: source.access_token,
          tenant_id: source.external_account_id,
          invoice_id: external_id
        )

        sync_invoice!(Array(payload.fetch("Invoices", [])).first || {})
        source.update!(status: :active, last_synced_at: Time.current, last_error: nil)
      rescue KeyError, OauthClient::Error => error
        source.update!(status: :error, last_error: error.message)
        raise
      end

      private
        attr_reader :source, :client

        def sync_invoice!(payload)
          return unless sales_invoice?(payload)

          invoice_external_id = payload.fetch("InvoiceID")
          contact = payload["Contact"].is_a?(Hash) ? payload["Contact"] : {}
          invoice = source.invoices.find_or_initialize_by(
            account: source.account,
            external_id: invoice_external_id
          )
          online_invoice_url = online_invoice_url_for(invoice:, payload:)

          Invoice.transaction do
            customer = Customer.sync_from_provider!(
              invoice_source: source,
              external_id: contact["ContactID"].presence || "invoice:#{invoice_external_id}",
              name: contact["Name"],
              email: contact["EmailAddress"],
              observed_at: parse_date(payload["DateString"] || payload["Date"])
            )

            invoice.update!(
              customer: customer,
              number: payload["InvoiceNumber"],
              invoice_type: payload["Type"],
              provider_status: payload["Status"],
              status: InvoiceStatus.normalize(payload["Status"]),
              currency: payload["CurrencyCode"],
              amount_due: payload["AmountDue"],
              amount_paid: payload["AmountPaid"],
              total: payload["Total"],
              issued_on: parse_date(payload["DateString"] || payload["Date"]),
              due_on: parse_date(payload["DueDateString"] || payload["DueDate"]),
              paid_on: parse_date(payload["FullyPaidOnDate"]),
              completed_on: completed_on(payload),
              contact_external_id: contact["ContactID"],
              contact_name: contact["Name"],
              provider_data: {
                updated_date_utc: payload["UpdatedDateUTC"],
                reference: payload["Reference"],
                amount_credited: payload["AmountCredited"],
                online_invoice_url:
              }.compact,
              raw_data: payload,
              synced_at: Time.current
            )
          end
        end

        def sales_invoice?(payload)
          payload["Type"].to_s.casecmp?("ACCREC")
        end

        def online_invoice_url_for(invoice:, payload:)
          existing_url = invoice.provider_data["online_invoice_url"].presence
          return existing_url if existing_url
          return unless online_invoice_available?(payload)
          return if @skip_online_invoice_enrichment
          return if @online_invoice_enrichment_requests.to_i >= ONLINE_INVOICE_ENRICHMENT_LIMIT

          @online_invoice_enrichment_requests = @online_invoice_enrichment_requests.to_i + 1

          response = client.online_invoice(
            access_token: source.access_token,
            tenant_id: source.external_account_id,
            invoice_id: payload.fetch("InvoiceID")
          )

          Array(response["OnlineInvoices"]).first.to_h["OnlineInvoiceUrl"].presence
        rescue OauthClient::Error => error
          @skip_online_invoice_enrichment = true
          Rails.logger.warn(
            "xero.online_invoice_url_unavailable " \
              "invoice_source_id=#{source.id} invoice_id=#{payload["InvoiceID"]} error=#{error.message}"
          )
          nil
        end

        def online_invoice_available?(payload)
          InvoiceStatus.normalize(payload["Status"]) == "open" && payload["AmountDue"].to_d.positive?
        end

        def completed_on(payload)
          parse_date(payload["FullyPaidOnDate"]) if payload["Status"].to_s.casecmp?("PAID")
        end

        def parse_date(value)
          return if value.blank?

          milliseconds = value.to_s.match(%r{\A/Date\((-?\d+)})&.captures&.first
          return Time.at(milliseconds.to_i / 1000.0).utc.to_date if milliseconds

          Date.parse(value.to_s)
        rescue Date::Error
          nil
        end
    end
  end
end
