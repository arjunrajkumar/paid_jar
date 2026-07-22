module Madmin
  class OutboundEmailConnectionsController < Madmin::ResourceController
    def disconnect
      @record.disconnect!
      redirect_to resource.show_path(@record), notice: "Outbound email disconnected."
    end
  end
end
