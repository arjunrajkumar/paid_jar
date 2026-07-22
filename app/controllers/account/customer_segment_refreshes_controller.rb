class Account::CustomerSegmentRefreshesController < ApplicationController
  require_account_admin

  def create
    Current.account.refresh_customer_segments!

    redirect_to account_settings_path(script_name: Current.account.slug),
      notice: "Debtor ratings refreshed."
  end
end
