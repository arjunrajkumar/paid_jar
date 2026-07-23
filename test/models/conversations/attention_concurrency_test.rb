require "test_helper"
require "timeout"

class Conversations::AttentionConcurrencyTest < ActiveSupport::TestCase
  setup do
    unique_name = "Attention concurrency #{SecureRandom.uuid}"
    @account_id, @conversation_id = Thread.new do
      account = Account.create!(name: unique_name)
      conversation = account.conversations.create!(
        attention_required_at: 1.hour.ago
      )
      [ account.id, conversation.id ]
    end.value
  end

  teardown do
    account_id = @account_id
    Thread.new { Account.find_by(id: account_id)&.destroy! }.value if account_id
  end

  test "a new inbound cannot be erased by stale attention recomputation" do
    calculated = Queue.new
    continue_recomputation = Queue.new
    inbound_acquired_lock = Queue.new
    new_received_at = Time.current
    recompute_thread = nil
    inbound_thread = nil

    calculation = lambda do |_conversation|
      calculated << true
      continue_recomputation.pop
      nil
    end
    attention_singleton = Conversations::Attention.singleton_class
    original_calculation = attention_singleton.instance_method(
      :outstanding_attention_at
    )
    attention_singleton.define_method(:outstanding_attention_at, &calculation)
    attention_singleton.send(:private, :outstanding_attention_at)
    begin
      recompute_thread = Thread.new do
        conversation = Conversation.find(@conversation_id)
        Conversations::Attention.recompute!(conversation:)
      end
      Timeout.timeout(2) { calculated.pop }
      inbound_thread = Thread.new do
        conversation = Conversation.find(@conversation_id)
        account = Account.find(@account_id)
        conversation.with_lock do
          inbound_acquired_lock << true
          message = conversation.conversation_messages.create!(
            account:,
            direction: :inbound,
            kind: :customer_email,
            status: :received,
            received_at: new_received_at,
            matching_status: :unmatched,
            matching_method: :none
          )
          Conversations::Attention.require_for_message!(message)
        end
      end
      begin
        Timeout.timeout(0.25) { inbound_acquired_lock.pop }
      rescue Timeout::Error
        nil
      end
      continue_recomputation << true
      recompute_thread.join
      inbound_thread.join
    ensure
      attention_singleton.define_method(
        :outstanding_attention_at,
        original_calculation
      )
      attention_singleton.send(:private, :outstanding_attention_at)
    end

    attention_required_at = Thread.new do
      Conversation.find(@conversation_id).attention_required_at
    end.value
    assert_equal new_received_at.change(usec: 0),
      attention_required_at.change(usec: 0)
  ensure
    continue_recomputation << true if recompute_thread&.alive?
    recompute_thread&.join
    inbound_thread&.join
  end
end
