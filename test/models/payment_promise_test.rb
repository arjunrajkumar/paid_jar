require "test_helper"

class PaymentPromiseTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @source_message = create_source_message
  end

  test "records an active promise from a received customer reply" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )

    assert_predicate promise, :status_active?
    assert_equal @invoice.account, promise.account
    assert_equal @invoice, promise.invoice
    assert_equal @source_message, promise.source_message
    assert_equal Date.new(2026, 8, 3), promise.promised_on
    assert_equal Date.new(2026, 8, 4), promise.follow_up_on
    assert_equal promise, @source_message.payment_promise
  end

  test "recording a new promise supersedes the existing active promise" do
    first = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )
    second = PaymentPromise.record!(
      invoice: @invoice,
      source_message: create_source_message(provider_message_id: "customer-reply-2"),
      promised_on: Date.new(2026, 8, 6)
    )

    assert_predicate first.reload, :status_superseded?
    assert_predicate second, :status_active?
    assert_equal [ second ], @invoice.payment_promises.status_active
  end

  test "recording the same source message is idempotent" do
    first = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )
    replay = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 7)
    )

    assert_equal first, replay
    assert_equal Date.new(2026, 8, 3), replay.promised_on
    assert_equal 1, @invoice.payment_promises.count
  end

  test "requires its account and source message to belong to the same invoice" do
    other_account = Account.create!(name: "Other Promise Account")
    other_source = @source_message.dup
    other_source.provider_message_id = "customer-reply-other-invoice"
    promise = PaymentPromise.new(
      account: other_account,
      invoice: @invoice,
      source_message: other_source,
      promised_on: Date.new(2026, 8, 3)
    )

    assert_not promise.valid?
    assert_includes promise.errors[:account], "must match invoice account"
    assert_includes promise.errors[:source_message], "must belong to the same account and invoice"
  end

  test "requires its source message to be a received inbound message" do
    outbound_message = build_message(
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: Time.current,
      received_at: nil
    )
    promise = PaymentPromise.new(
      account: @invoice.account,
      invoice: @invoice,
      source_message: outbound_message,
      promised_on: Date.new(2026, 8, 3)
    )

    assert_not promise.valid?
    assert_includes promise.errors[:source_message], "must be a received inbound message"
  end

  test "allows only one active promise per invoice" do
    PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )
    duplicate = PaymentPromise.new(
      account: @invoice.account,
      invoice: @invoice,
      source_message: create_source_message(provider_message_id: "customer-reply-duplicate"),
      promised_on: Date.new(2026, 8, 7)
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:invoice], "already has an active payment promise"
  end

  test "enforces one active promise per invoice in the database" do
    PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )
    duplicate = PaymentPromise.new(
      account: @invoice.account,
      invoice: @invoice,
      source_message: create_source_message(provider_message_id: "customer-reply-race"),
      promised_on: Date.new(2026, 8, 7)
    )

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "enforces the active invoice reservation in the database" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )

    assert_raises ActiveRecord::StatementInvalid do
      promise.update_column(:active_invoice_id, nil)
    end
  end

  test "clears the active reservation when a promise is resolved" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )

    promise.update!(status: :fulfilled)

    assert_nil promise.active_invoice_id
    assert_predicate promise, :status_fulfilled?
  end

  test "finds active promises due on or before the requested date" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )

    assert_empty PaymentPromise.due_for_follow_up(on: Date.new(2026, 8, 3))
    assert_includes PaymentPromise.due_for_follow_up(on: Date.new(2026, 8, 4)), promise
    assert_includes PaymentPromise.due_for_follow_up(on: Date.new(2026, 8, 8)), promise

    promise.followed_up!

    assert_empty PaymentPromise.due_for_follow_up(on: Date.new(2026, 8, 8))
  end

  test "records an explicit terminal state when follow-up delivery fails" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )

    promise.follow_up_failed!

    assert_predicate promise, :status_follow_up_failed?
    assert_nil promise.active_invoice_id
  end

  test "atomically records a confirmed follow-up delivery and resolves the promise" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )
    message = build_message(
      direction: :outbound,
      kind: :promise_follow_up,
      status: :pending,
      delivery_job_id: "promise-delivery-job",
      delivery_attempted_at: Time.current,
      sent_at: nil,
      received_at: nil,
      provider_message_id: nil
    ).tap(&:save!)
    promise.update!(follow_up_message: message)

    assert promise.record_follow_up_sent!(
      job_id: "promise-delivery-job",
      provider_message_id: "confirmed-follow-up",
      provider_thread_id: "confirmed-thread"
    )

    assert_predicate promise.reload, :status_followed_up?
    assert_predicate message.reload, :status_sent?
    assert_equal "confirmed-follow-up", message.provider_message_id
  end

  test "does not let a different job record the follow-up outcome" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )
    message = build_message(
      direction: :outbound,
      kind: :promise_follow_up,
      status: :pending,
      delivery_job_id: "owner-job",
      delivery_attempted_at: Time.current,
      sent_at: nil,
      received_at: nil,
      provider_message_id: nil
    ).tap(&:save!)
    promise.update!(follow_up_message: message)

    assert_not promise.record_follow_up_failed!(
      job_id: "other-job",
      failure_reason: "Should not win"
    )

    assert_predicate promise.reload, :status_active?
    assert_predicate message.reload, :status_pending?
  end

  test "does not resolve a promise twice" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )

    promise.fulfill!
    promise.followed_up!

    assert_predicate promise, :status_fulfilled?
  end

  test "does not replay a source message against another invoice" do
    other_invoice = @invoice.dup
    other_invoice.external_id = "payment-promise-replay-other-invoice"
    other_invoice.save!
    PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )

    error = assert_raises ActiveRecord::RecordInvalid do
      PaymentPromise.record!(
        invoice: other_invoice,
        source_message: @source_message,
        promised_on: Date.new(2026, 8, 7)
      )
    end

    assert_includes error.record.errors[:source_message], "must belong to the same account and invoice"
  end

  test "links one valid outbound promise follow-up message" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )
    follow_up = build_message(
      direction: :outbound,
      kind: :promise_follow_up,
      status: :pending,
      sent_at: nil,
      received_at: nil
    )

    assert promise.update(follow_up_message: follow_up)
    assert_equal promise, follow_up.payment_promise_follow_up
  end

  test "rejects an invalid promise follow-up message" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )

    assert_not promise.update(follow_up_message: @source_message)
    assert_includes promise.errors[:follow_up_message], "must be an outbound promise follow-up"
  end

  test "requires its follow-up message to belong to the same account and invoice" do
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @source_message,
      promised_on: Date.new(2026, 8, 3)
    )
    other_invoice = @invoice.dup
    other_invoice.external_id = "payment-promise-follow-up-other-invoice"
    other_invoice.save!
    other_follow_up = build_message(
      invoice: other_invoice,
      direction: :outbound,
      kind: :promise_follow_up,
      status: :pending,
      sent_at: nil,
      received_at: nil,
      provider_message_id: nil
    )

    assert_not promise.update(follow_up_message: other_follow_up)
    assert_includes promise.errors[:follow_up_message], "must belong to the same account and invoice"
  end

  private
    def create_source_message(attributes = {})
      build_message(attributes).tap(&:save!)
    end

    def build_message(attributes = {})
      InvoiceMessage.new(
        {
          account: @invoice.account,
          invoice: @invoice,
          direction: :inbound,
          kind: :customer_reply,
          status: :received,
          received_at: Time.current,
          provider_message_id: "customer-reply-1",
          from_address: "customer@example.com",
          to_addresses: [ "billing@example.com" ],
          cc_addresses: [],
          subject: "Re: Invoice INV-001",
          body: "I will pay on August 3."
        }.merge(attributes)
      )
    end
end
