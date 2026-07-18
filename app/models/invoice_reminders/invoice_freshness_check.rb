class InvoiceReminders::InvoiceFreshnessCheck
  class Error < StandardError; end

  def self.call(invoice)
    new(invoice).call
  end

  def initialize(invoice)
    @invoice = invoice
  end

  def call
    refresh_started_at = Time.current
    refreshed_invoice = invoice.invoice_source.sync_invoice!(external_id: invoice.external_id)

    return refreshed_invoice.reload if freshly_synced?(refreshed_invoice, refresh_started_at:)

    raise Error, "Provider did not return a fresh state for invoice #{invoice.external_id}"
  end

  private
    attr_reader :invoice

    def freshly_synced?(refreshed_invoice, refresh_started_at:)
      refreshed_invoice&.synced_at.present? && refreshed_invoice.synced_at >= refresh_started_at
    end
end
