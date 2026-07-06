class InvoicesController < ApplicationController
  def index
    @xero_integration = Current.account.accounting_integrations.xero.first
    @invoices = Current.account.invoices.includes(:accounting_integration).recent
  end
end
