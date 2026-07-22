class ConversationMessages::Content < Data.define(
  :from_address,
  :to_addresses,
  :cc_addresses,
  :subject,
  :body
)
  def self.from_mail(mail_message)
    new(
      from_address: Array(mail_message.from).first,
      to_addresses: Array(mail_message.to),
      cc_addresses: Array(mail_message.cc),
      subject: mail_message.subject,
      body: message_body(mail_message)
    )
  end

  def attributes
    to_h
  end

  class << self
    private
      def message_body(mail_message)
        if mail_message.multipart?
          mail_message.text_part&.body&.decoded.presence ||
            mail_message.html_part&.body&.decoded.to_s
        else
          mail_message.body.decoded
        end
      end
  end
end
