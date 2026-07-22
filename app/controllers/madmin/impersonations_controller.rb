module Madmin
  class ImpersonationsController < Madmin::ApplicationController
    def destroy
      session.delete(:platform_admin_impersonated_user_id)
      redirect_to main_app.madmin_root_url(script_name: nil),
        notice: "User impersonation stopped."
    end
  end
end
