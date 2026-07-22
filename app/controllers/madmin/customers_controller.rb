module Madmin
  class CustomersController < Madmin::ResourceController
    def refresh_customer_segment
      @record.refresh_customer_segment!
      redirect_to resource.show_path(@record), notice: "Customer segment refreshed."
    end
  end
end
