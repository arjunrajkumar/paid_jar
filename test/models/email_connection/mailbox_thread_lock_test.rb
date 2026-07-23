require "test_helper"
require "timeout"

class EmailConnection::MailboxThreadLockTest < ActiveSupport::TestCase
  test "serializes work for the same account mailbox and Gmail thread" do
    account = accounts(:paid_jar)
    connection = email_connections(:paid_jar_gmail)
    first_entered = Queue.new
    release_first = Queue.new
    second_entered = Queue.new

    first = Thread.new do
      EmailConnection::MailboxThreadLock.synchronize(
        account:,
        provider_account_id: connection.provider_account_id,
        provider_thread_id: "serialized-thread"
      ) do
        first_entered << true
        release_first.pop
      end
    end
    Timeout.timeout(2) { first_entered.pop }
    second = Thread.new do
      EmailConnection::MailboxThreadLock.synchronize(
        account:,
        provider_account_id: connection.provider_account_id,
        provider_thread_id: "serialized-thread"
      ) do
        second_entered << true
      end
    end

    assert_raises(ThreadError) { second_entered.pop(true) }
    release_first << true
    Timeout.timeout(2) { second_entered.pop }
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end

  test "checks local registry entries back in after repeated acquisition timeouts" do
    account = accounts(:paid_jar)
    connection = email_connections(:paid_jar_gmail)
    lock_class = EmailConnection::MailboxThreadLock
    lock_class.stubs(:acquire_local_lock).returns(false)

    3.times do
      assert_raises EmailConnection::MailboxThreadLock::Unavailable do
        lock_class.synchronize(
          account:,
          provider_account_id: connection.provider_account_id,
          provider_thread_id: "timed-out-thread"
        ) { flunk "timed-out lock must not enter its block" }
      end
    end

    assert_empty lock_class.send(:local_locks)
  end
end
