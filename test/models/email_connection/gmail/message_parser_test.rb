require "test_helper"

class EmailConnection::Gmail::MessageParserTest < ActiveSupport::TestCase
  test "consumes MIME body bytes already decoded by the Google client" do
    body = "A realistic customer reply with café."
    message = Google::Apis::GmailV1::Message.from_json(
      {
        id: "gmail-json-message",
        threadId: "gmail-json-thread",
        internalDate: "1721648000000",
        labelIds: [ "INBOX" ],
        payload: {
          mimeType: "text/plain",
          headers: [
            { name: "From", value: "customer@example.com" },
            { name: "Subject", value: "Re: INV-001" }
          ],
          body: {
            data: Base64.urlsafe_encode64(body, padding: false),
            size: body.bytesize
          }
        }
      }.to_json
    )

    assert_equal body.b, message.payload.body.data

    parsed = EmailConnection::Gmail::MessageParser.call(message)

    assert_equal body, parsed.body
    assert_not_includes parsed.parse_warnings, "invalid_body_encoding"
  end

  test "parses nested multipart email and preserves Gmail and RFC facts" do
    html = part("text/html", "<p>HTML fallback</p>")
    plain = part("text/plain", "Plain customer reply")
    attachment = part("text/plain", "secret attachment", filename: "private.txt")
    message = gmail_message(
      parts: [
        Google::Apis::GmailV1::MessagePart.new(
          mime_type: "multipart/alternative",
          parts: [ html, plain ]
        ),
        attachment
      ],
      headers: {
        "From" => "Customer Person <CUSTOMER@example.com>",
        "To" => "Billing <billing@paymentreminder.example>",
        "Cc" => "Accounts <accounts@example.com>",
        "Bcc" => "Archive <archive@example.com>",
        "Reply-To" => "Replies <reply@example.com>",
        "Subject" => "Re: INV-001",
        "Message-ID" => "<reply-1@example.com>",
        "In-Reply-To" => "<sent-1@example.com>",
        "References" => "<older@example.com> <sent-1@example.com> <older@example.com>"
      }
    )

    parsed = EmailConnection::Gmail::MessageParser.call(message)

    assert_equal "gmail-message-1", parsed.provider_message_id
    assert_equal "gmail-thread-1", parsed.provider_thread_id
    assert_equal Time.zone.at(1_721_648_000), parsed.internal_date
    assert_equal [ "INBOX" ], parsed.label_ids
    assert_equal "customer@example.com", parsed.from_address
    assert_equal [ "billing@paymentreminder.example" ], parsed.to_addresses
    assert_equal [ "accounts@example.com" ], parsed.cc_addresses
    assert_equal [ "archive@example.com" ], parsed.bcc_addresses
    assert_equal [ "reply@example.com" ], parsed.reply_to_addresses
    assert_equal "Plain customer reply", parsed.body
    assert_equal "<reply-1@example.com>", parsed.internet_message_id
    assert_equal [ "<sent-1@example.com>" ], parsed.in_reply_to_message_ids
    assert_equal [ "<older@example.com>", "<sent-1@example.com>" ], parsed.reference_message_ids
    refute_includes parsed.body, "secret attachment"
  end

  test "does not silently choose one mailbox from a multiple-address From header" do
    message = gmail_message(
      parts: [ part("text/plain", "Customer reply") ],
      headers: {
        "From" => "First <first@example.com>, Second <second@example.com>",
        "Subject" => "Question about INV-001"
      }
    )

    parsed = EmailConnection::Gmail::MessageParser.call(message)

    assert_nil parsed.from_address
    assert_includes parsed.parse_warnings, "multiple_from_addresses"
  end

  test "does not read a nested message attachment as the email body" do
    attached_message = Google::Apis::GmailV1::MessagePart.new(
      mime_type: "message/rfc822",
      parts: [ part("text/plain", "Private attachment for invoice ATTACHED-999") ]
    )
    message = gmail_message(parts: [
      attached_message,
      part("text/plain", "Actual customer reply")
    ])

    parsed = EmailConnection::Gmail::MessageParser.call(message)

    assert_equal "Actual customer reply", parsed.body
    refute_includes parsed.body, "ATTACHED-999"
  end

  test "does not descend into a multipart attachment" do
    disposition = Google::Apis::GmailV1::MessagePartHeader.new(
      name: "Content-Disposition",
      value: "attachment"
    )
    multipart_attachment = Google::Apis::GmailV1::MessagePart.new(
      mime_type: "multipart/mixed",
      headers: [ disposition ],
      parts: [ part("text/plain", "Private multipart attachment") ]
    )
    message = gmail_message(parts: [
      multipart_attachment,
      part("text/plain", "Visible customer reply")
    ])

    parsed = EmailConnection::Gmail::MessageParser.call(message)

    assert_equal "Visible customer reply", parsed.body
    refute_includes parsed.body, "Private multipart attachment"
  end

  test "attachment-only invoice text is not a relevance signal" do
    attached_message = Google::Apis::GmailV1::MessagePart.new(
      mime_type: "message/rfc822",
      filename: "forwarded.eml",
      parts: [ part("text/plain", "Private attachment for invoice INV-001") ]
    )
    message = gmail_message(
      parts: [ part("text/plain", "A private unrelated message"), attached_message ],
      headers: { "From" => "stranger@example.net" }
    )

    parsed = EmailConnection::Gmail::MessageParser.call(message)
    result = ConversationMessages::EmailMatcher.call(
      account: accounts(:paid_jar),
      provider_account_id: email_connections(:paid_jar_gmail).provider_account_id,
      parsed_message: parsed,
      direction: :inbound
    )

    assert_equal "A private unrelated message", parsed.body
    assert_not result.relevant?
  end

  test "sanitizes HTML and detects automatic responses" do
    message = gmail_message(
      parts: [ part("text/html", "<p>Hello <strong>there</strong></p><script>bad()</script>") ],
      headers: {
        "From" => "mailer-daemon@example.com",
        "Auto-Submitted" => "auto-replied",
        "Subject" => "Automatic response"
      }
    )

    parsed = EmailConnection::Gmail::MessageParser.call(message)

    assert_includes parsed.body, "Hello there"
    refute_includes parsed.body, "<strong>"
    assert parsed.automatic
  end

  test "returns a safe reviewable result for malformed content" do
    malformed = gmail_message(parts: [
      Google::Apis::GmailV1::MessagePart.new(
        mime_type: "text/plain",
        body: Google::Apis::GmailV1::MessagePartBody.new(data: "\xFF".b)
      )
    ])

    parsed = EmailConnection::Gmail::MessageParser.call(malformed)

    assert_equal "gmail-message-1", parsed.provider_message_id
    assert_includes parsed.parse_warnings, "invalid_body_encoding"
  end

  test "normalizes invalid UTF-8, removes NUL bytes, and truncates oversized bodies" do
    content = ("x" * 60_001).b
    content.setbyte(0, 255)
    content.setbyte(1, 0)
    parsed = EmailConnection::Gmail::MessageParser.call(
      gmail_message(parts: [ part("text/plain", content) ])
    )

    assert_predicate parsed.body, :valid_encoding?
    refute_includes parsed.body, "\u0000"
    assert_operator parsed.body.bytesize, :<=, 60_000
    assert_includes parsed.parse_warnings, "body_truncated"
  end

  test "missing MIME payload preserves provider facts in a minimal parse-error result" do
    message = Google::Apis::GmailV1::Message.new(
      id: "gmail-minimal",
      thread_id: "known-gmail-thread",
      internal_date: "1721648000000",
      label_ids: [ "SPAM" ]
    )

    parsed = EmailConnection::Gmail::MessageParser.call(message)

    assert_equal "gmail-minimal", parsed.provider_message_id
    assert_equal "known-gmail-thread", parsed.provider_thread_id
    assert_equal Time.zone.at(1_721_648_000), parsed.internal_date
    assert_equal [ "SPAM" ], parsed.label_ids
    assert_nil parsed.body
    assert_includes parsed.parse_warnings, "parse_error"
  end

  test "unexpected parser errors propagate" do
    parser = EmailConnection::Gmail::MessageParser.new(
      gmail_message(parts: [ part("text/plain", "Customer reply") ])
    )
    parser.stubs(:header_values).raises(NoMethodError, "unexpected parser bug")

    error = assert_raises(NoMethodError) { parser.call }

    assert_equal "unexpected parser bug", error.message
  end

  private
    def gmail_message(parts:, headers: {})
      Google::Apis::GmailV1::Message.new(
        id: "gmail-message-1",
        thread_id: "gmail-thread-1",
        internal_date: "1721648000000",
        label_ids: [ "INBOX" ],
        payload: Google::Apis::GmailV1::MessagePart.new(
          mime_type: "multipart/mixed",
          headers: headers.map do |name, value|
            Google::Apis::GmailV1::MessagePartHeader.new(name:, value:)
          end,
          parts:
        )
      )
    end

    def part(mime_type, content, filename: nil)
      Google::Apis::GmailV1::MessagePart.new(
        mime_type:,
        filename:,
        body: Google::Apis::GmailV1::MessagePartBody.new(
          data: content
        )
      )
    end
end
