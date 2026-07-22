class PaymentPromiseMailer < ApplicationMailer
  def follow_up(payment_promise)
    prepare_follow_up(payment_promise)

    mail(
      to: @customer.reminder_email_addresses,
      from: email_address_with_name(
        @account.invoice_reminder_from_email,
        @account.invoice_reminder_from_name.presence || @account.name
      ),
      subject: "Payment status: Invoice #{@invoice_reference}"
    )
  end

  private
    def prepare_follow_up(payment_promise)
      @payment_promise = payment_promise
      @invoice = payment_promise.invoice
      @account = payment_promise.account
      @customer = @invoice.customer
      @invoice_reference = @invoice.number.presence || @invoice.external_id
      @due_date = formatted_date(@invoice.due_on)
      @promised_on = formatted_date(payment_promise.promised_on)
      @amount_due = formatted_amount_due
      @online_invoice_url = @invoice.online_invoice_url
    end

    def formatted_date(date)
      date.present? ? I18n.l(date, format: :long) : "Not available"
    end

    def formatted_amount_due
      return "Amount unavailable" if @invoice.amount_due.nil? || @invoice.currency.blank?

      amount = BigDecimal(@invoice.amount_due.to_s)
      precision = amount.frac.zero? ? 0 : 2

      ActiveSupport::NumberHelper.number_to_currency(
        amount,
        unit: "#{@invoice.currency.upcase} ",
        format: "%u%n",
        precision:
      )
    end
end
