module Authorization
  extend ActiveSupport::Concern

  included do
    before_action :ensure_can_access_account, if: :authenticated_account_access?
  end

  class_methods do
    def allow_unauthorized_access(**options)
      skip_before_action :ensure_can_access_account, **options
    end
  end

  private
    def authenticated_account_access?
      Current.account.present? && authenticated?
    end

    def ensure_can_access_account
      unless Current.account.active? && Current.user&.active?
        respond_to do |format|
          format.html { redirect_to root_path }
          format.json { head :forbidden }
        end
      end
    end
end
