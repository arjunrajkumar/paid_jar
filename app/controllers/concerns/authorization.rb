module Authorization
  extend ActiveSupport::Concern

  included do
    before_action :ensure_can_access_account, if: :authenticated_account_access?
  end

  class_methods do
    def allow_unauthorized_access(**options)
      skip_before_action :ensure_can_access_account, **options
    end

    def require_account_admin(**options)
      before_action :ensure_account_admin, **options
    end
  end

  private
    def authenticated_account_access?
      authenticated? && (Current.account.present? || requested_account_id.present?)
    end

    def ensure_can_access_account
      return if exact_account_access?

      deny_access(account_access_denied_message)
    end

    def ensure_account_admin
      return if Current.identity&.platform_admin? && exact_account_access?
      return if Current.user&.admin? && Current.user.account_id == Current.account&.id

      deny_access("You need to be an account owner or administrator to do that.")
    end

    def exact_account_access?
      Current.account&.active? &&
        Current.user&.active? &&
        Current.user.account_id == Current.account.id &&
        (requested_account_id.blank? || requested_account_id == Current.account.external_account_id)
    end

    def requested_account_id
      request.env["paidjar.external_account_id"]
    end

    def account_access_denied_message
      "Choose a PaymentReminder account you can access."
    end

    def deny_access(message)
      respond_to do |format|
        format.html { redirect_to root_url(script_name: nil), alert: message }
        format.json { head :forbidden }
      end
    end
end
