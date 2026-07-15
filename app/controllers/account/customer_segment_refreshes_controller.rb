class Account::CustomerSegmentRefreshesController < ApplicationController
  def create
    Receivable.refresh_for_account!(Current.account)

    redirect_to account_settings_path(script_name: Current.account.slug),
      notice: "Customer segments refreshed."
  end
end
