class PaymentPromises::ManualRecorder
  def self.call(invoice:, promised_on:, note: nil, recorded_at: Time.current)
    new(
      invoice:,
      promised_on:,
      note:,
      recorded_at:
    ).call
  end

  def initialize(invoice:, promised_on:, note:, recorded_at:)
    @invoice = invoice
    @promised_on = promised_on
    @note = note
    @recorded_at = recorded_at
  end

  def call
    raise ArgumentError, "Payment promises can only be recorded for an outstanding invoice." unless invoice.outstanding?

    PaymentPromise.transaction do
      source_message = invoice.invoice_messages.create!(source_message_attributes)
      PaymentPromise.record!(invoice:, source_message:, promised_on:)
    end
  end

  private
    attr_reader :invoice, :promised_on, :note, :recorded_at

    def source_message_attributes
      {
        account: invoice.account,
        direction: :inbound,
        kind: :customer_reply,
        status: :received,
        received_at: recorded_at,
        from_address: invoice.customer.synced_reminder_email_address,
        to_addresses: [ invoice.account.invoice_reminder_from_email ].compact,
        subject: "Payment promise recorded manually",
        body: note.presence || "Payment promised for #{promised_on}."
      }
    end
end
