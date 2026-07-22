require "test_helper"

class PaymentPromises::DeliveryReservationTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @account.update!(automatic_invoice_reminders_enabled: true)
    @payment_promise = create_promise
  end

  test "atomically reserves and links an auditable follow-up message" do
    travel_to follow_up_time do
      assert_difference -> { @invoice.conversation_messages.count }, 1 do
        @reservation = reserve
      end
    end

    assert_predicate @reservation, :reserved?
    assert_equal @payment_promise.reload.follow_up_message, @reservation.message
    assert_equal Conversation.for_invoice!(invoice: @invoice), @reservation.message.conversation
    assert_predicate @reservation.message, :status_pending?
    assert_predicate @reservation.message, :kind_promise_follow_up?
    assert_equal "promise-delivery-job", @reservation.message.delivery_job_id
    assert_equal email_connections(:paid_jar_gmail), @reservation.connection
    assert_equal "Payment status: Invoice INV-001", @reservation.mail_message.subject
  end

  test "reuses only the pending follow-up owned by the same job" do
    travel_to follow_up_time do
      first = reserve

      assert_no_difference -> { @invoice.conversation_messages.count } do
        second = reserve
        assert_predicate second, :reserved?
        assert_equal first.message, second.message
      end

      foreign_job = reserve(delivery_job_id: "other-job")
      assert_not_predicate foreign_job, :reserved?
      assert_equal "outbound_delivery_in_progress", foreign_job.reason
    end
  end

  test "authoritatively resolves a paid promise instead of reserving delivery" do
    @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.current)

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        @reservation = reserve
      end
    end

    assert_predicate @reservation, :resolved?
    assert_equal :fulfilled, @reservation.resolution
    assert_predicate @payment_promise.reload, :status_fulfilled?
  end

  test "returns eligibility reasons without reserving delivery" do
    @account.update!(automatic_invoice_reminders_enabled: false)

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        @reservation = reserve
      end
    end

    assert_not_predicate @reservation, :reserved?
    assert_equal "disabled_account", @reservation.reason
    assert_predicate @payment_promise.reload, :status_active?
  end

  private
    def reserve(delivery_job_id: "promise-delivery-job")
      PaymentPromises::DeliveryReservation.call(
        payment_promise: @payment_promise.reload,
        delivery_job_id:
      )
    end

    def create_promise
      PaymentPromise.record!(
        invoice: @invoice,
        source_message: @invoice.conversation_messages.create!(
          account: @account,
          conversation: Conversation.for_invoice!(invoice: @invoice),
          direction: :inbound,
          kind: :customer_reply,
          status: :received,
          received_at: Time.current,
          provider_message_id: "delivery-reservation-promise-source",
          from_address: "customer@example.com",
          to_addresses: [ "billing@paymentreminder.example" ],
          cc_addresses: [],
          subject: "Re: Invoice INV-001",
          body: "I will pay on August 3."
        ),
        promised_on: Date.new(2026, 8, 3)
      )
    end

    def follow_up_time
      Time.zone.local(2026, 8, 4, 9)
    end
end
