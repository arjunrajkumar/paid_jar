module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
    helper_method :email_address_pending_authentication

    etag { Current.identity.id if authenticated? }

    include Authentication::ViaMagicLink
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
      before_action :resume_session, **options
      allow_unauthorized_access **options
    end

    def require_unauthenticated_access(**options)
      allow_unauthenticated_access **options
      before_action :redirect_authenticated_user, **options
    end

    def disallow_account_scope(**options)
      before_action :redirect_account_scoped_request, **options
    end
  end

  private
    def authenticated?
      Current.identity.present?
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      if session = find_session_by_cookie
        set_current_session session
      end
    end

    def request_authentication
      if Current.account.present?
        session[:return_to_after_authenticating] = request.url
      end

      redirect_to_login_url
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def login_url
      new_session_url(script_name: nil)
    end

    def redirect_to_login_url
      redirect_to login_url, allow_other_host: true
    end

    def redirect_account_scoped_request
      redirect_to url_for(script_name: nil), status: :see_other if request.script_name.present?
    end

    def find_session_by_cookie
      Session.find_signed(cookies.signed[:session_token]) if cookies.signed[:session_token].present?
    end

    def start_new_session_for(identity)
      identity.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        set_current_session session
      end
    end

    def set_current_session(session)
      Current.session = session
      cookies.signed.permanent[:session_token] = { value: session.signed_id, httponly: true, same_site: :lax }
    end

    def terminate_session
      Current.session&.destroy
      cookies.delete(:session_token)
    end

    def session_token
      cookies[:session_token]
    end

    def redirect_authenticated_user
      redirect_to root_path if authenticated?
    end
end
