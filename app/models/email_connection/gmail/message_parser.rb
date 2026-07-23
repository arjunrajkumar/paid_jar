class EmailConnection::Gmail::MessageParser
  BODY_LIMIT = 60_000
  SUBJECT_LIMIT = 10_000

  class MalformedMessageError < StandardError; end

  ParsedMessage = Data.define(
    :provider_message_id,
    :provider_thread_id,
    :internal_date,
    :label_ids,
    :from_address,
    :to_addresses,
    :cc_addresses,
    :bcc_addresses,
    :reply_to_addresses,
    :subject,
    :body,
    :internet_message_id,
    :in_reply_to_message_ids,
    :reference_message_ids,
    :automatic,
    :parse_warnings
  ) do
    def spam?
      label_ids.include?("SPAM")
    end
  end

  def self.call(message)
    new(message).call
  end

  def initialize(message)
    @message = message
    @warnings = []
  end

  def call
    build_parsed_message
  rescue MalformedMessageError
    warnings << "parse_error"
    build_minimal_message
  end

  private
    attr_reader :message, :warnings

    def build_parsed_message
      raise MalformedMessageError, "missing Gmail payload" if message.payload.blank?

      headers = header_values(message.payload)
      plain_parts, html_parts = body_parts(message.payload)
      body = plain_parts.find(&:present?) || sanitize_html(html_parts.find(&:present?))
      from_addresses = addresses(headers["from"])
      warnings << "multiple_from_addresses" if from_addresses.many?

      ParsedMessage.new(
        provider_message_id: message.id.to_s,
        provider_thread_id: message.thread_id.to_s,
        internal_date: parse_internal_date,
        label_ids: Array(message.label_ids).map(&:to_s).uniq,
        from_address: from_addresses.one? ? from_addresses.first : nil,
        to_addresses: addresses(headers["to"]),
        cc_addresses: addresses(headers["cc"]),
        bcc_addresses: addresses(headers["bcc"]),
        reply_to_addresses: addresses(headers["reply-to"]),
        subject: bounded_text(headers["subject"]&.first, SUBJECT_LIMIT, "subject_truncated"),
        body: bounded_text(body, BODY_LIMIT, "body_truncated"),
        internet_message_id: header_message_ids(headers["message-id"]).first,
        in_reply_to_message_ids: header_message_ids(headers["in-reply-to"]),
        reference_message_ids: header_message_ids(headers["references"]),
        automatic: automatic?(headers),
        parse_warnings: warnings.uniq.freeze
      ).freeze
    end

    def build_minimal_message
      ParsedMessage.new(
        provider_message_id: message.id.to_s,
        provider_thread_id: message.thread_id.to_s,
        internal_date: parse_internal_date,
        label_ids: Array(message.label_ids).map(&:to_s).uniq,
        from_address: nil,
        to_addresses: [],
        cc_addresses: [],
        bcc_addresses: [],
        reply_to_addresses: [],
        subject: nil,
        body: nil,
        internet_message_id: nil,
        in_reply_to_message_ids: [],
        reference_message_ids: [],
        automatic: false,
        parse_warnings: warnings.uniq.freeze
      ).freeze
    end

    def parse_internal_date
      milliseconds = message.internal_date.to_s
      raise ArgumentError, "invalid internal date" unless milliseconds.match?(/\A\d+\z/)

      Time.zone.at(milliseconds.to_i / 1000.0)
    end

    def header_values(payload)
      Array(payload&.headers).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |header, values|
        values[header.name.to_s.downcase] << safe_utf8(header.value)
      end
    end

    def body_parts(part)
      return [ [], [] ] unless part
      return [ [], [] ] if attachment?(part)

      children = Array(part.parts)
      if children.any?
        return children.each_with_object([ [], [] ]) do |child, collected|
          child_plain, child_html = body_parts(child)
          collected.first.concat(child_plain)
          collected.last.concat(child_html)
        end
      end

      decoded = normalize_body(part.body&.data)
      case part.mime_type.to_s.downcase
      when "text/plain" then [ [ decoded ], [] ]
      when "text/html" then [ [], [ decoded ] ]
      else [ [], [] ]
      end
    end

    def attachment?(part)
      return true if part.mime_type.to_s.casecmp?("message/rfc822")
      return true if part.filename.present?

      Array(part.headers).any? do |header|
        header.name.to_s.casecmp?("Content-Disposition") &&
          header.value.to_s.downcase.include?("attachment")
      end
    end

    def normalize_body(data)
      return if data.blank?

      text = data.to_s.dup
      text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY
      warnings << "invalid_body_encoding" unless text.valid_encoding?
      safe_utf8(text)
    end

    def sanitize_html(html)
      return if html.blank?

      ActionView::Base.full_sanitizer.sanitize(html)
    end

    def addresses(values)
      Array(values).flat_map do |value|
        Mail::AddressList.new(value).addresses.filter_map do |address|
          normalized = address.address.to_s.strip.downcase
          normalized if normalized.match?(URI::MailTo::EMAIL_REGEXP) && normalized.length <= 254
        end
      rescue Mail::Field::ParseError
        warnings << "invalid_address"
        []
      end.uniq
    end

    def header_message_ids(values)
      Array(values).flat_map do |value|
        matches = value.to_s.scan(/<[^<>]+>/)
        matches.presence || value.to_s.split
      end.filter_map { |value| safe_utf8(value).strip.presence }.uniq
    end

    def automatic?(headers)
      auto_submitted = headers["auto-submitted"]&.first.to_s.downcase
      precedence = headers["precedence"]&.first.to_s.downcase
      return_path_present = headers.key?("return-path")
      return_path = headers["return-path"]&.first.to_s.strip.downcase
      from = headers["from"]&.join(" ").to_s.downcase

      (auto_submitted.present? && auto_submitted != "no") ||
        precedence.in?(%w[bulk junk list]) ||
        %w[x-autoreply x-autorespond x-auto-response-suppress].any? { |name| headers[name].present? } ||
        (return_path_present && return_path.in?([ "", "<>" ])) ||
        from.match?(/mailer-daemon|postmaster/)
    end

    def bounded_text(value, limit, warning)
      normalized = safe_utf8(value).delete("\u0000")
      return normalized if normalized.bytesize <= limit

      warnings << warning
      normalized.byteslice(0, limit).scrub
    end

    def safe_utf8(value)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    end
end
