module Madmin
  class EmailConnectionsController < Madmin::ResourceController
    def disconnect
      @record.disconnect!
      redirect_to resource.show_path(@record), notice: "Email disconnected."
    end
  end
end
