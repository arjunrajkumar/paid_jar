require "test_helper"
require "timeout"

class Conversations::AcknowledgementConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class SeparateConnectionMessage < ActiveRecord::Base
    self.table_name = "conversation_messages"
  end

  setup do
    ids = Thread.new do
      account = Account.create!(
        name: "Acknowledgement concurrency #{SecureRandom.uuid}"
      )
      actor = account.users.create!(name: "Concurrency actor", role: :owner)
      invoice_source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: SecureRandom.uuid
      )
      customer = invoice_source.customers.create!(
        account:,
        external_id: SecureRandom.uuid,
        name: "Concurrency customer",
        email: "concurrency-customer@example.com"
      )
      invoice = invoice_source.invoices.create!(
        account:,
        customer:,
        external_id: SecureRandom.uuid,
        number: "INV-CONCURRENCY",
        status: :open
      )
      connection = account.create_email_connection!(
        provider: :gmail,
        provider_account_id: "acknowledgement-concurrency-provider",
        connected_email: "billing-concurrency@example.com",
        access_token: "access-token",
        refresh_token: "refresh-token",
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
        status: :active
      )
      canonical = Conversation.for_invoice!(invoice:)
      linked_source = account.conversations.create!(
        canonical_conversation: canonical
      )
      import_source = account.conversations.create!
      visible = linked_source.conversation_messages.create!(
        account:,
        invoice:,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "acknowledgement-visible",
        provider_thread_id: "acknowledgement-concurrency-thread",
        internet_message_id: "<acknowledgement-visible@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: 2.hours.ago,
        from_address: customer.email,
        matching_status: :ambiguous,
        matching_method: :none,
        review_required: true,
        reviewed_at: 90.minutes.ago,
        reviewed_by_user: actor,
        review_outcome: :manual_match,
        review_reasons: [ "invoice_thread_conflict" ]
      )
      canonical.update!(attention_required_at: visible.received_at)

      [
        account.id,
        actor.id,
        invoice.id,
        connection.id,
        canonical.id,
        visible.id,
        import_source.id,
        connection.provider_account_id,
        connection.credential_generation
      ]
    end
    ids = Timeout.timeout(5) { ids.value }
    @account_id,
      @actor_id,
      @invoice_id,
      @connection_id,
      @conversation_id,
      @visible_message_id,
      @source_id,
      @provider_account_id,
      @connection_generation = ids
  end

  teardown do
    account_id = @account_id
    Thread.new { Account.find_by(id: account_id)&.destroy! }.value if account_id
  end

  test "handled acknowledgement persists only membership verified before a concurrent import" do
    conversation = Conversation.find(@conversation_id)
    token = Conversations::WorkUnitSnapshot.token_for(conversation:)
    verified = Queue.new
    continue_acknowledgement = Queue.new
    thread_errors = Queue.new
    acknowledgement_thread = nil
    snapshot_singleton = Conversations::WorkUnitSnapshot.singleton_class
    original_verification = snapshot_singleton.instance_method(:verify!)
    pausing_verification = lambda do |**arguments|
      payload = original_verification.bind_call(
        Conversations::WorkUnitSnapshot,
        **arguments
      )
      verified << payload
      continue_acknowledgement.pop
      payload
    end
    snapshot_singleton.define_method(:verify!, &pausing_verification)

    begin
      acknowledgement_thread = Thread.new do
        ActiveRecord::Base.transaction(isolation: :read_committed) do
          Conversations::Acknowledgement.call(
            conversation: Conversation.find(@conversation_id),
            actor_user: User.find(@actor_id),
            work_unit_token: token
          )
        end
      rescue StandardError => error
        thread_errors << error
      end
      Timeout.timeout(2) { verified.pop }

      imported_at = 1.hour.ago
      import_thread = Thread.new do
        insert_concurrent_message!(received_at: imported_at)
      end
      imported_message_id = Timeout.timeout(5) { import_thread.value }

      continue_acknowledgement << true
      Timeout.timeout(5) { acknowledgement_thread.join }
    ensure
      continue_acknowledgement << true if acknowledgement_thread&.alive?
      acknowledgement_thread&.join
      snapshot_singleton.define_method(:verify!, original_verification)
    end

    raise thread_errors.pop unless thread_errors.empty?
    handled_event = Conversation.find(@conversation_id)
      .conversation_events
      .kind_conversation_attention_cleared
      .actor_kind_user
      .sole
    assert_equal [ @visible_message_id ],
      handled_event.metadata.fetch("visible_message_ids")
    assert_not_includes handled_event.metadata.fetch("visible_message_ids"),
      imported_message_id

    source = Conversation.find(@source_id)
    imported = ConversationMessage.find(imported_message_id)
    canonical = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: imported,
      target_invoice: Invoice.find(@invoice_id),
      actor_user: User.find(@actor_id),
      work_unit_token: conversation_work_unit_token(source)
    )
    Conversations::Attention.recompute!(conversation: canonical)

    assert_equal imported_at.change(usec: 0),
      canonical.reload.attention_required_at.change(usec: 0)

    Conversations::Acknowledgement.call(
      conversation: canonical,
      actor_user: User.find(@actor_id),
      work_unit_token: conversation_work_unit_token(canonical)
    )

    assert_nil canonical.reload.attention_required_at
  end

  private
    def insert_concurrent_message!(received_at:)
      connection_config = ActiveRecord::Base
        .connection_db_config
        .configuration_hash
        .merge(pool: 1)
      message_class = SeparateConnectionMessage
      message_class.establish_connection(connection_config)
      internet_message_id = "<acknowledgement-concurrent@example.com>"
      now = Time.current
      message_class.insert_all!(
        [
          {
            account_id: @account_id,
            conversation_id: @source_id,
            email_connection_id: @connection_id,
            email_connection_generation: @connection_generation,
            provider_account_id: @provider_account_id,
            provider_message_id: "acknowledgement-concurrent",
            provider_thread_id: "acknowledgement-concurrency-thread",
            internet_message_id:,
            internet_message_id_digest: Digest::SHA256.hexdigest(
              internet_message_id
            ),
            direction: "inbound",
            kind: "customer_email",
            status: "received",
            received_at:,
            from_address: "unknown-concurrency-sender@example.com",
            matching_status: "ambiguous",
            matching_method: "none",
            review_required: true,
            review_reasons: [ "invoice_thread_conflict" ],
            automatic: false,
            delivery_uncertain: false,
            to_addresses: [],
            cc_addresses: [],
            bcc_addresses: [],
            reply_to_addresses: [],
            in_reply_to_message_ids: [],
            reference_message_ids: [],
            provider_metadata: {},
            created_at: now,
            updated_at: now
          }
        ]
      )
      message_class.find_by!(
        provider_account_id: @provider_account_id,
        provider_message_id: "acknowledgement-concurrent"
      ).id
    ensure
      message_class&.connection_pool&.disconnect!
    end
end
