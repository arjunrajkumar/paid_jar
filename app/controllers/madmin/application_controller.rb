module Madmin
  class ApplicationController < Madmin::BaseController
    GENERIC_MUTATION_ACTIONS = %w[new create edit update destroy].freeze
    ALLOWED_GENERIC_MUTATIONS = {
      "madmin/accounts" => %w[edit update],
      "madmin/customer_email_addresses" => %w[edit update destroy],
      "madmin/customer_segments" => %w[edit update],
      "madmin/invoice_schedules" => %w[edit update],
      "madmin/notification_subscriptions" => %w[edit update],
      "madmin/users" => %w[edit update]
    }.freeze

    include Rails.application.routes.url_helpers
    include Authentication

    disallow_account_scope
    before_action :require_platform_admin
    before_action :prevent_unsafe_generic_mutation
    around_action :record_platform_admin_operation

    helper_method :madmin_action_allowed?

    private
      def require_platform_admin
        return if Current.identity&.platform_admin?

        redirect_to main_app.root_url(script_name: nil),
          alert: "You do not have platform administrator access."
      end

      def login_url
        main_app.new_session_url(script_name: nil)
      end

      def redirect_account_scoped_request
        return if request.script_name.blank?

        query = request.query_string.present? ? "?#{request.query_string}" : ""
        redirect_to "#{request.base_url}#{request.path_info}#{query}", status: :see_other
      end

      def prevent_unsafe_generic_mutation
        return unless respond_to?(:resource, true)
        return unless action_name.in?(GENERIC_MUTATION_ACTIONS)
        return if madmin_action_allowed?(action_name)

        redirect_to resource.index_path,
          alert: "Use a purpose-built administrator action for this operation.",
          status: :see_other
      end

      def madmin_action_allowed?(action)
        action.to_s.in?(ALLOWED_GENERIC_MUTATIONS.fetch(controller_path, []))
      end

      def record_platform_admin_operation
        return yield unless request.post? || request.patch? || request.put? || request.delete?

        actor = Current.identity
        yield
        return unless response.redirect?

        PlatformAdminEvent.record!(
          actor:,
          action: platform_admin_action_name,
          target: defined?(@record) ? @record : nil,
          account: platform_admin_event_account,
          metadata: platform_admin_event_metadata
        )
      end

      def platform_admin_action_name
        "#{controller_path.delete_prefix("madmin/").tr("/", ".")}.#{action_name}"
      end

      def platform_admin_event_account
        record = defined?(@record) ? @record : nil
        return record if record.is_a?(::Account)
        return record.account if record&.respond_to?(:account)
        return record.customer.account if record&.respond_to?(:customer)
        return record.user.account if record&.respond_to?(:user)
        return Current.account if controller_path == "madmin/impersonations"

        nil
      end

      def platform_admin_event_metadata
        record = defined?(@record) ? @record : nil
        changed_fields = record&.previous_changes&.keys.to_a - %w[created_at updated_at]

        { changed_fields: }
      end
  end
end
