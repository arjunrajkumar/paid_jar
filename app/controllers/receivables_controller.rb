class ReceivablesController < ApplicationController
  def index
    @invoice_sources = InvoiceSource.connected_for(Current.account)
    @has_synced_invoices = Current.account.invoices.exists?
    @as_of = Date.current
    @receivables = Current.account.receivables.active.includes(:customer).to_a
    @receivables.sort_by! { |receivable| receivable_sort_key(receivable) }
  end

  private
    def receivable_sort_key(receivable)
      [ receivable_status_priority(receivable), receivable.customer.name.downcase ]
    end

    def receivable_status_priority(receivable)
      return 0 if receivable.uncollectible_invoice_count.positive?
      return 1 if receivable.outstanding_invoice_count.positive? || receivable.open_invoice_count.positive?

      2
    end
end
