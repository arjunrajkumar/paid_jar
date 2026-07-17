module Customers
  class EmailAddressesController < ApplicationController
    before_action :set_customer

    def index
      prepare_page
    end

    def create
      @email_address = @customer.additional_email_addresses.build(email_address_params)

      if @email_address.save
        redirect_to customer_email_addresses_path(@customer), notice: "Recipient added."
      else
        prepare_page
        render :index, status: :unprocessable_entity
      end
    end

    def destroy
      @customer.additional_email_addresses.find(params[:id]).destroy!

      redirect_to customer_email_addresses_path(@customer), notice: "Recipient removed."
    end

    private
      def set_customer
        @customer = Current.account.customers.find(params[:customer_id])
      end

      def prepare_page
        @email_address ||= @customer.additional_email_addresses.build
        @email_addresses = @customer.additional_email_addresses.where.not(id: nil).to_a
      end

      def email_address_params
        params.expect(customer_email_address: [ :email ])
      end
  end
end
