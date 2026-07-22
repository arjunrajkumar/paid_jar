require "test_helper"

class PaymentPromises::ScheduleFollowUpsJobTest < ActiveJob::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
  end

  test "enqueues active promises due today or earlier" do
    travel_to Time.zone.local(2026, 8, 4, 9) do
      due_today = create_promise(promised_on: Date.new(2026, 8, 3), source_id: "due-today")
      overdue = create_promise(
        invoice: create_invoice(external_id: "overdue-promise-invoice"),
        promised_on: Date.new(2026, 7, 31),
        source_id: "overdue"
      )

      assert_enqueued_jobs 2, only: PaymentPromises::FollowUpJob do
        PaymentPromises::ScheduleFollowUpsJob.perform_now
      end
      assert_enqueued_with(job: PaymentPromises::FollowUpJob, args: [ due_today.id ])
      assert_enqueued_with(job: PaymentPromises::FollowUpJob, args: [ overdue.id ])
    end
  end

  test "does not enqueue future or resolved promises" do
    travel_to Time.zone.local(2026, 8, 4, 9) do
      create_promise(promised_on: Date.new(2026, 8, 4), source_id: "future")
      resolved = create_promise(
        invoice: create_invoice(external_id: "resolved-promise-invoice"),
        promised_on: Date.new(2026, 8, 3),
        source_id: "resolved"
      )
      resolved.fulfill!

      assert_no_enqueued_jobs only: PaymentPromises::FollowUpJob do
        PaymentPromises::ScheduleFollowUpsJob.perform_now
      end
    end
  end

  private
    def create_promise(invoice: @invoice, promised_on:, source_id:)
      PaymentPromise.record!(
        invoice:,
        source_message: invoice.conversation_messages.create!(
          account: invoice.account,
          conversation: Conversation.for_invoice!(invoice:),
          direction: :inbound,
          kind: :customer_reply,
          status: :received,
          received_at: Time.current,
          provider_message_id: "promise-source-#{source_id}",
          from_address: "customer@example.com",
          to_addresses: [ "billing@paymentreminder.example" ],
          cc_addresses: [],
          subject: "Re: Invoice #{invoice.number}",
          body: "I will pay on #{promised_on}."
        ),
        promised_on:
      )
    end

    def create_invoice(external_id:)
      @invoice.dup.tap do |invoice|
        invoice.external_id = external_id
        invoice.number = external_id
        invoice.save!
      end
    end
end
