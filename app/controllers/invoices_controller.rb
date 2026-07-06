class InvoicesController < ApplicationController
  before_action :set_xero_integration

  def index
    set_page_and_extract_portion_from Current.account.invoices.includes(:accounting_integration).recent
  end

  private

  def set_xero_integration
    if xero_integration = Current.account.accounting_integrations.xero.connected.first
      @xero_integration = xero_integration
    else
      redirect_to new_xero_connection_path
    end
  end
end
