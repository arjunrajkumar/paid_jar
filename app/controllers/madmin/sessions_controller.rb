module Madmin
  class SessionsController < Madmin::ResourceController
    def revoke
      if @record == Current.session
        redirect_to resource.show_path(@record), alert: "Sign out normally to revoke the current session."
        return
      end

      @record.destroy!
      redirect_to resource.index_path, notice: "Session revoked."
    end
  end
end
