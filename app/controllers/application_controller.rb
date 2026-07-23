class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
  include CurrentTimezone
  include RequestForgeryProtection

  etag { "v1" }
  stale_when_importmap_changes

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  helper_method :inbox_attention_count

  private
    def inbox_attention_count
      @inbox_attention_count ||= if Current.account
        Conversations::AttentionSummary.call(account: Current.account).count
      else
        0
      end
    end
end
