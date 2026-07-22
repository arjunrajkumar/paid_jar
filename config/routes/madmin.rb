# Below are the routes for madmin
namespace :madmin do
  namespace :invoice_sources do
    namespace :stripe do
      resources :installation_claims
    end
  end
  namespace :invoice_sources do
    namespace :webhooks do
      resources :events do
        post :retry_processing, on: :member
      end
    end
  end
  resources :users do
    member do
      post :impersonate
      post :suspend
      post :reactivate
      post :change_role
    end
  end
  resource :impersonation, only: :destroy
  namespace :account do
    resources :external_id_sequences
  end
  resources :notification_subscriptions
  resources :platform_admin_events
  resources :payment_promises do
    member do
      post :fulfill
      post :cancel
      post :enqueue_follow_up
    end
  end
  resources :sessions do
    post :revoke, on: :member
  end
  resources :invoice_sources do
    member do
      post :refresh
      post :disconnect
    end
  end
  resources :magic_links do
    post :revoke, on: :member
  end
  resources :invoice_schedules
  resources :accounts do
    member do
      post :refresh_customer_segments
      post :enqueue_invoice_reminders
    end
  end
  resources :customers do
    post :refresh_customer_segment, on: :member
  end
  resources :customer_email_addresses
  resources :customer_segments
  resources :external_identities
  resources :identities
  resources :invoices do
    member do
      post :send_manual_reminder
      get :new_payment_promise
      post :record_payment_promise
    end
  end
  resources :email_connections do
    post :disconnect, on: :member
  end
  resources :conversation_messages
  resources :invoice_reminders
  resources :invoice_reminder_suppressions
  root to: "dashboard#show"
end
