class CustomersController < ApplicationController
  def index
    redirect_to home_path
  end

  def show
    @customer = customer_collection.find!(params[:id])
  end

  private
    def customer_collection
      @customer_collection ||= Customers::Collection.new(
        Current.account.invoices.includes(:invoice_source).recent.to_a
      )
    end
end
