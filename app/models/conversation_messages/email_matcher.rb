class ConversationMessages::EmailMatcher
  ParticipantMatch = Data.define(
    :customers,
    :unknown_addresses,
    :duplicate_customer_address
  )

  Result = Data.define(
    :relevant,
    :conversation,
    :customer,
    :invoice,
    :matching_status,
    :matching_method,
    :review_required,
    :review_reasons
  ) do
    def relevant?
      relevant
    end
  end

  def self.call(account:, parsed_message:, direction:, provider_account_id:)
    new(account:, parsed_message:, direction:, provider_account_id:).call
  end

  def initialize(account:, parsed_message:, direction:, provider_account_id:)
    @account = account
    @message = parsed_message
    @direction = direction.to_s
    @provider_account_id = provider_account_id.to_s.strip.presence ||
      raise(ArgumentError, "provider_account_id is required")
  end

  def call
    strong_match = strong_conversation_match
    return ambiguous(*strong_match.fetch(:reasons)) if strong_match[:ambiguous]

    invoice_matches = matching_invoices(account.invoices)
    return ambiguous("multiple_invoice_references") if invoice_matches.many?
    invoice_match = invoice_matches.first

    conversation = strong_match[:conversation]
    if participant_match.duplicate_customer_address
      return ambiguous("duplicate_customer_address")
    end
    if matching_customers.many?
      reason = direction == "outbound" ? "multiple_customer_recipients" : "duplicate_customer_address"
      return ambiguous(reason)
    end
    customer = matching_customers.one? ? matching_customers.first : nil
    context_customer = conversation&.customer || customer || invoice_match&.customer

    if (reply_to_conflict = reply_to_conflict_reason(context_customer:))
      return ambiguous(reply_to_conflict, context_customer:)
    end

    if conversation
      if invoice_match && invoice_match != conversation.invoice
        return ambiguous("invoice_thread_conflict")
      end

      return ambiguous("address_conflicts_with_thread") if
        customer && conversation.customer && customer != conversation.customer

      return result(
        relevant: true,
        conversation:,
        customer: conversation.customer || customer,
        invoice: conversation.invoice,
        matching_status: :matched,
        matching_method: strong_match.fetch(:method),
        reasons: review_reasons(context_customer:)
      )
    end

    if customer
      if invoice_match
        return ambiguous("address_conflicts_with_invoice") if invoice_match.customer != customer

        invoice = invoice_match
        return result(
          relevant: true,
          conversation: invoice.conversation,
          customer:,
          invoice:,
          matching_status: :matched,
          matching_method: :invoice_reference,
          reasons: review_reasons(context_customer:)
        )
      end

      return result(
        relevant: true,
        conversation: nil,
        customer:,
        invoice: nil,
        matching_status: :unmatched,
        matching_method: :customer_only,
        reasons: review_reasons(context_customer:) + [ "invoice_unmatched" ]
      )
    end

    if invoice_match
      return result(
        relevant: true,
        conversation: nil,
        customer: nil,
        invoice: nil,
        matching_status: :unmatched,
        matching_method: :invoice_reference,
        reasons: review_reasons(context_customer:) + [ "invoice_reference_without_customer" ]
      )
    end

    result(
      relevant: false,
      conversation: nil,
      customer: nil,
      invoice: nil,
      matching_status: :unmatched,
      matching_method: :none,
      reasons: []
    )
  end

  private
    attr_reader :account, :message, :direction, :provider_account_id

    def strong_conversation_match
      thread_conversations = conversations_for_provider_thread
      return { ambiguous: true, reasons: [ "multiple_gmail_threads" ] } if thread_conversations.many?

      rfc_conversations = conversations_for_rfc_headers
      return { ambiguous: true, reasons: [ "multiple_rfc_threads" ] } if rfc_conversations.many?

      thread_conversation = thread_conversations.first
      rfc_conversation = rfc_conversations.first
      if thread_conversation && rfc_conversation && thread_conversation != rfc_conversation
        return { ambiguous: true, reasons: [ "gmail_rfc_thread_conflict" ] }
      end

      if thread_conversation
        { conversation: thread_conversation, method: :gmail_thread, ambiguous: false }
      elsif rfc_conversation
        { conversation: rfc_conversation, method: :rfc_headers, ambiguous: false }
      else
        { conversation: nil, method: nil, ambiguous: false }
      end
    end

    def conversations_for_provider_thread
      return [] if message.provider_thread_id.blank?

      ids = account.conversation_messages
        .where(provider_account_id:, provider_thread_id: message.provider_thread_id)
        .where.not(matching_status: ConversationMessage::MATCHING_STATUSES.fetch(:ambiguous))
        .distinct
        .pluck(:conversation_id)
      account.conversations.where(id: ids).to_a
    end

    def conversations_for_rfc_headers
      message_ids = [ *message.in_reply_to_message_ids, *message.reference_message_ids.reverse ].uniq
      conversation_ids = message_ids.flat_map do |message_id|
        digest = Digest::SHA256.hexdigest(message_id)
        account.conversation_messages
          .where(provider_account_id:, internet_message_id_digest: digest)
          .where(internet_message_id: message_id)
          .where.not(matching_status: ConversationMessage::MATCHING_STATUSES.fetch(:ambiguous))
          .pluck(:conversation_id)
      end.uniq
      account.conversations.where(id: conversation_ids).to_a
    end

    def matching_customers
      participant_match.customers
    end

    def matching_invoices(scope)
      text = [ message.subject, message.body ].compact.join("\n")
      return [] if text.blank?

      scope.select do |invoice|
        [ invoice.number, invoice.external_id ].compact.any? do |reference|
          reference.present? && text.match?(/(?<![[:alnum:]])#{Regexp.escape(reference)}(?![[:alnum:]])/i)
        end
      end
    end

    def participant_match
      @participant_match ||= match_participant_addresses(participant_addresses)
    end

    def reply_to_match
      @reply_to_match ||= match_participant_addresses(message.reply_to_addresses)
    end

    def match_participant_addresses(raw_addresses)
      addresses = normalized_addresses(raw_addresses)
      primary_matches = account.customers.where(email: addresses).pluck(:id, :email)
      additional_matches = CustomerEmailAddress
        .joins(:customer)
        .where(customers: { account_id: account.id }, email: addresses)
        .pluck(:customer_id, :email)
      customer_ids_by_address = addresses.index_with { [] }
      [ *primary_matches, *additional_matches ].each do |customer_id, address|
        customer_ids_by_address[address.to_s.strip.downcase] << customer_id
      end
      customer_ids_by_address.each_value(&:uniq!)
      customer_ids = customer_ids_by_address.values.flatten.uniq
      known_addresses = customer_ids_by_address.filter_map do |address, customer_ids_for_address|
        address if customer_ids_for_address.any?
      end

      ParticipantMatch.new(
        customers: account.customers.where(id: customer_ids).to_a.freeze,
        unknown_addresses: addresses.empty? || (addresses - known_addresses).any?,
        duplicate_customer_address: customer_ids_by_address.values.any?(&:many?)
      ).freeze
    end

    def participant_addresses
      addresses = if direction == "inbound"
        [ message.from_address ]
      else
        [ *message.to_addresses, *message.cc_addresses, *message.bcc_addresses ]
      end

      normalized_addresses(addresses)
    end

    def normalized_addresses(addresses)
      Array(addresses).filter_map { |address| address.to_s.strip.downcase.presence }.uniq
    end

    def ambiguous(*reasons, context_customer: nil)
      result(
        relevant: true,
        conversation: nil,
        customer: nil,
        invoice: nil,
        matching_status: :ambiguous,
        matching_method: :none,
        reasons: review_reasons(context_customer:) + reasons
      )
    end

    def result(
      relevant:,
      conversation:,
      customer:,
      invoice:,
      matching_status:,
      matching_method:,
      reasons:
    )
      normalized_reasons = reasons.compact.map(&:to_s).uniq
      Result.new(
        relevant:,
        conversation:,
        customer:,
        invoice:,
        matching_status: matching_status.to_s,
        matching_method: matching_method.to_s,
        review_required: normalized_reasons.any? || matching_status.to_s != "matched",
        review_reasons: normalized_reasons.freeze
      ).freeze
    end

    def review_reasons(context_customer: nil)
      reasons = message.parse_warnings.dup
      reasons << "automatic_response" if message.automatic
      reasons << "spam" if message.spam?
      if participant_match.unknown_addresses
        reasons << (direction == "inbound" ? "unknown_sender" : "unknown_recipient")
      end
      reasons.concat(reply_to_review_reasons(context_customer:))
      reasons
    end

    def reply_to_conflict_reason(context_customer:)
      return unless direction == "inbound"
      return if message.reply_to_addresses.empty?
      return "duplicate_reply_to_address" if reply_to_match.duplicate_customer_address
      return "reply_to_customer_conflict" if reply_to_match.customers.many?
      return unless context_customer && reply_to_match.customers.one?
      return if reply_to_match.customers.first == context_customer

      "reply_to_customer_conflict"
    end

    def reply_to_review_reasons(context_customer:)
      return [] unless direction == "inbound"
      return [] if message.reply_to_addresses.empty?

      reasons = []
      reasons << "unknown_reply_to" if reply_to_match.unknown_addresses
      if context_customer.nil? && reply_to_match.customers.any?
        reasons << "reply_to_without_customer_context"
      end
      reasons
    end
end
