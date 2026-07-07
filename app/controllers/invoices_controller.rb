class InvoicesController < ApplicationController
  before_action :set_xero_source

  def index
    set_page_and_extract_portion_from Current.account.invoices.includes(:invoice_source).recent
  end

  private

  def set_xero_source
    if xero_source = Current.account.invoice_sources.xero.connected.first
      @xero_source = xero_source
    else
      redirect_to new_xero_connection_path
    end
  end
end
