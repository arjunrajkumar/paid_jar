require "test_helper"

class Madmin::OperationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin_account = sign_up_and_complete(email_address: "operations-platform-admin@example.com")
    PlatformAdminAccess.stubs(:allowed?).returns(true)
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "global indexes include other accounts and their users" do
    get madmin_accounts_url

    assert_response :success
    assert_select "td", text: accounts(:paid_jar).name
    assert_select "td", text: @admin_account.name

    get madmin_users_url

    assert_response :success
    assert_select "td", text: users(:arjun).name
    assert_select "td", text: @admin_account.users.owner.sole.name
  end

  test "operational resource pages render their purpose-built actions without secrets" do
    invoice = invoices(:xero_invoice)
    promise = PaymentPromises::ManualRecorder.call(
      invoice:,
      promised_on: Date.current + 3.days,
      note: "Admin resource smoke test"
    )
    event = InvoiceSources::Webhooks::Event.create!(
      invoice_source: invoice_sources(:xero),
      provider: "xero",
      provider_event_id: "admin-resource-event",
      event_type: "UPDATE",
      payload: { "events" => [ { "resourceType" => "CONTACT" } ] },
      status: :failed
    )
    identity = Identity.create!(email_address: "resource-access@example.com")
    user = accounts(:paid_jar).users.create!(name: "Resource User", role: :member, identity:)
    magic_link = identity.magic_links.create!
    other_session = identity.sessions.create!

    paths = [
      madmin_account_url(accounts(:paid_jar)),
      madmin_customer_url(customers(:xero_customer)),
      madmin_invoice_source_url(invoice_sources(:xero)),
      madmin_invoice_sources_webhooks_event_url(event),
      madmin_invoice_url(invoice),
      madmin_payment_promise_url(promise),
      madmin_email_connection_url(email_connections(:paid_jar_gmail)),
      madmin_magic_link_url(magic_link),
      madmin_session_url(other_session),
      madmin_user_url(user)
    ]

    paths.each do |path|
      get path
      assert_response :success, path
    end

    get madmin_invoice_source_url(invoice_sources(:xero))
    assert_not_includes response.body, "access-token"
    assert_not_includes response.body, "refresh-token"

    get madmin_magic_link_url(magic_link)
    assert_not_includes response.body, magic_link.code
  end

  test "queues account reminder scheduling and invoice source refresh" do
    assert_enqueued_with(job: Account::InvoiceReminders::ScheduleAccountJob, args: [ accounts(:paid_jar) ]) do
      post enqueue_invoice_reminders_madmin_account_url(accounts(:paid_jar))
    end
    assert_redirected_to madmin_account_url(accounts(:paid_jar))

    assert_enqueued_with(job: InvoiceSources::RefreshJob, args: [ invoice_sources(:xero) ]) do
      post refresh_madmin_invoice_source_url(invoice_sources(:xero))
    end
    assert_redirected_to madmin_invoice_source_url(invoice_sources(:xero))
  end

  test "queues a manual invoice reminder" do
    invoice = invoices(:xero_invoice)

    assert_difference -> { PlatformAdminEvent.count }, 1 do
      assert_enqueued_with(job: InvoiceReminders::ManualSendJob, args: [ invoice.id ]) do
        post send_manual_reminder_madmin_invoice_url(invoice)
      end
    end

    assert_redirected_to madmin_invoice_url(invoice)
    event = PlatformAdminEvent.order(:id).last
    assert_equal "invoices.send_manual_reminder", event.action
    assert_equal invoice, event.target
    assert_equal invoice.account, event.account
  end

  test "does not queue a manual reminder for a settled invoice" do
    invoice = invoices(:xero_invoice)
    invoice.update!(status: :paid, paid_on: Date.current, amount_due: 0)

    assert_no_enqueued_jobs only: InvoiceReminders::ManualSendJob do
      post send_manual_reminder_madmin_invoice_url(invoice)
    end

    assert_redirected_to madmin_invoice_url(invoice)
    assert_equal "Only an outstanding invoice can receive a reminder.", flash[:alert]
  end

  test "records and resolves a payment promise" do
    invoice = invoices(:xero_invoice)
    promised_on = Date.current + 5.days

    get new_payment_promise_madmin_invoice_url(invoice)
    assert_response :success
    assert_select "form[action=?]", record_payment_promise_madmin_invoice_path(invoice)

    assert_difference [ -> { PaymentPromise.count }, -> { ConversationMessage.count } ], 1 do
      post record_payment_promise_madmin_invoice_url(invoice), params: {
        payment_promise: {
          promised_on: promised_on.iso8601,
          note: "Customer confirmed by phone."
        }
      }
    end

    promise = PaymentPromise.order(:id).last
    assert_redirected_to madmin_payment_promise_url(promise)
    assert_equal promised_on, promise.promised_on
    assert_equal "Customer confirmed by phone.", promise.source_message.body

    post fulfill_madmin_payment_promise_url(promise)

    assert_redirected_to madmin_payment_promise_url(promise)
    assert_predicate promise.reload, :status_fulfilled?
  end

  test "retries failed webhooks and disconnects local Stripe access" do
    event = InvoiceSources::Webhooks::Event.create!(
      invoice_source: invoice_sources(:xero),
      provider: "xero",
      provider_event_id: "admin-retry-event",
      event_type: "UPDATE",
      resource_type: "CONTACT",
      payload: { "events" => [ { "resourceType" => "CONTACT" } ] },
      status: :failed,
      last_error: "Temporary provider failure"
    )

    assert_enqueued_with(job: InvoiceSources::Webhooks::ProcessJob, args: [ event ]) do
      post retry_processing_madmin_invoice_sources_webhooks_event_url(event)
    end

    stripe_source = @admin_account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "acct_admin_disconnect"
    )
    post disconnect_madmin_invoice_source_url(stripe_source)

    assert_redirected_to madmin_invoice_source_url(stripe_source)
    assert_predicate stripe_source.reload, :disconnected?
  end

  test "retries a terminally failed email receipt through an audited action" do
    connection = email_connections(:paid_jar_gmail)
    receipt = connection.email_message_receipts.create!(
      account: connection.account,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "terminal-admin-retry",
      discovered_at: Time.current,
      status: :failed,
      attempts: 5,
      last_error: "EmailConnection::Errors::PermanentProviderError"
    )

    assert_difference -> { PlatformAdminEvent.count }, 1 do
      assert_enqueued_with(
        job: EmailMessageReceipts::ProcessJob,
        args: [
          receipt.id,
          receipt.provider_account_id,
          receipt.email_connection_generation
        ]
      ) do
        post retry_processing_madmin_email_message_receipt_url(receipt)
      end
    end

    assert_redirected_to madmin_email_message_receipt_url(receipt)
    assert_predicate receipt.reload, :status_pending?
    assert_equal 0, receipt.attempts
    assert_nil receipt.last_error

    event = PlatformAdminEvent.order(:id).last
    assert_equal "email_message_receipts.retry_processing", event.action
    assert_equal receipt, event.target
    assert_equal receipt.account, event.account
  end

  test "does not manually retry a receipt that already has an automatic retry" do
    connection = email_connections(:paid_jar_gmail)
    receipt = connection.email_message_receipts.create!(
      account: connection.account,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "scheduled-admin-retry",
      discovered_at: Time.current,
      status: :failed,
      attempts: 1,
      next_retry_at: 5.minutes.from_now,
      last_error: "EmailConnection::Errors::TemporaryProviderError"
    )

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      post retry_processing_madmin_email_message_receipt_url(receipt)
    end

    assert_redirected_to madmin_email_message_receipt_url(receipt)
    assert_equal "Only terminally failed email receipts can be retried.", flash[:alert]
    assert_predicate receipt.reload, :status_failed?
  end

  test "audits an email receipt retry whose job cannot be enqueued" do
    connection = email_connections(:paid_jar_gmail)
    receipt = connection.email_message_receipts.create!(
      account: connection.account,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "terminal-admin-enqueue-failure",
      discovered_at: Time.current,
      status: :failed,
      attempts: 5,
      last_error: "EmailConnection::Errors::PermanentProviderError"
    )
    EmailMessageReceipts::ProcessJob
      .stubs(:enqueue)
      .with(receipt)
      .raises(ActiveJob::EnqueueError, "secret queue details")

    assert_difference -> { PlatformAdminEvent.count }, 1 do
      assert_raises(ActiveJob::EnqueueError) do
        post retry_processing_madmin_email_message_receipt_url(receipt)
      end
    end

    assert_predicate receipt.reload, :status_pending?

    event = PlatformAdminEvent.order(:id).last
    assert_equal "email_message_receipts.retry_processing_enqueue_failed", event.action
    assert_equal receipt, event.target
    assert_equal receipt.account, event.account
    assert_equal({ "error_class" => "ActiveJob::EnqueueError" }, event.metadata)
    assert_not_includes event.metadata.to_json, "secret queue details"
  end

  test "email receipts expose no generic mutation routes" do
    receipt = email_connections(:paid_jar_gmail).email_message_receipts.create!(
      account: accounts(:paid_jar),
      provider_account_id: email_connections(:paid_jar_gmail).provider_account_id,
      provider_message_id: "read-only-admin-receipt",
      discovered_at: Time.current
    )

    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(
        "/madmin/email_message_receipts/#{receipt.id}",
        method: :delete
      )
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(
        "/madmin/email_message_receipts/#{receipt.id}/edit",
        method: :get
      )
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(
        "/madmin/email_message_receipts",
        method: :post
      )
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(
        "/madmin/email_message_receipts/#{receipt.id}",
        method: :patch
      )
    end
  end

  test "email receipts remain available to platform admins for index and show" do
    receipt = email_connections(:paid_jar_gmail).email_message_receipts.create!(
      account: accounts(:paid_jar),
      provider_message_id: "read-only-visible-receipt",
      discovered_at: Time.current
    )

    get madmin_email_message_receipts_url
    assert_response :success
    get madmin_email_message_receipt_url(receipt)
    assert_response :success
  end

  test "email connections expose no generic mutation routes because receipts are durable" do
    connection = email_connections(:paid_jar_gmail)
    receipt = connection.email_message_receipts.create!(
      account: connection.account,
      provider_message_id: "durable-receipt-before-admin-delete",
      discovered_at: Time.current
    )

    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(
        "/madmin/email_connections/#{connection.id}",
        method: :delete
      )
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(
        "/madmin/email_connections/#{connection.id}/edit",
        method: :get
      )
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(
        "/madmin/email_connections",
        method: :post
      )
    end
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(
        "/madmin/email_connections/#{connection.id}",
        method: :patch
      )
    end
    assert EmailConnection.exists?(connection.id)
    assert EmailMessageReceipt.exists?(receipt.id)
  end

  test "disconnects Gmail and disables automatic reminders" do
    connection = email_connections(:paid_jar_gmail)
    connection.account.update!(automatic_invoice_reminders_enabled: true)

    post disconnect_madmin_email_connection_url(connection)

    assert_redirected_to madmin_email_connection_url(connection)
    assert_predicate connection.reload, :disconnected?
    assert_not connection.account.reload.automatic_invoice_reminders_enabled?
  end

  test "suspends and restores a user" do
    identity = Identity.create!(email_address: "managed-user@example.com")
    user = accounts(:paid_jar).users.create!(name: "Managed User", role: :member, identity:)

    post suspend_madmin_user_url(user)
    assert_not user.reload.active?

    post reactivate_madmin_user_url(user)
    assert_predicate user.reload, :active?

    post change_role_madmin_user_url(user), params: { role: "admin" }
    assert_predicate user.reload, :admin?
  end

  test "revokes one-time links and other sessions" do
    identity = Identity.create!(email_address: "revoked-access@example.com")
    magic_link = identity.magic_links.create!
    other_session = identity.sessions.create!

    post revoke_madmin_magic_link_url(magic_link)
    assert_not MagicLink.exists?(magic_link.id)

    post revoke_madmin_session_url(other_session)
    assert_not Session.exists?(other_session.id)
  end

  private
    def sign_up_and_complete(email_address:)
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Platform Admin" } }

      Identity.find_by!(email_address:).accounts.first
    end
end
