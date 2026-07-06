class InvoicesController < ApplicationController
  def index
    @xero_integration = Current.account.accounting_integrations.xero.connected.first
    return redirect_to new_xero_connection_path unless @xero_integration

    set_page_and_extract_portion_from Current.account.invoices.includes(:accounting_integration).recent
  end
end
