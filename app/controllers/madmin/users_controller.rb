module Madmin
  class UsersController < Madmin::ResourceController
    def impersonate
      unless @record.active? && !@record.system?
        redirect_to resource.show_path(@record), alert: "Only an active human user can be impersonated."
        return
      end

      session[:platform_admin_impersonated_user_id] = @record.id
      redirect_to main_app.invoices_url(script_name: @record.account.slug),
        notice: "You are now acting as #{@record.name} in #{@record.account.name}."
    end

    def suspend
      unless @record.active? && !@record.system?
        redirect_to resource.show_path(@record), alert: "This user cannot be suspended."
        return
      end

      @record.update!(active: false)
      redirect_to resource.show_path(@record), notice: "User access suspended."
    end

    def reactivate
      unless @record.identity.present? && !@record.system?
        redirect_to resource.show_path(@record), alert: "This user has no sign-in identity to reactivate."
        return
      end

      @record.update!(active: true)
      redirect_to resource.show_path(@record), notice: "User access restored."
    end

    def change_role
      role = params.require(:role)
      unless role.in?(%w[owner admin member]) && !@record.system?
        redirect_to resource.show_path(@record), alert: "Choose a valid human-user role."
        return
      end

      @record.update!(role:)
      redirect_to resource.show_path(@record), notice: "User role changed to #{role.humanize}."
    end
  end
end
