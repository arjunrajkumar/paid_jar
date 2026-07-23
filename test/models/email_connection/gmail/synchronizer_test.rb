require "test_helper"

class EmailConnection::Gmail::SynchronizerTest < ActiveJob::TestCase
  Message = Data.define(:id, :thread_id)
  Addition = Data.define(:message)
  History = Data.define(:id, :messages_added)
  Page = Data.define(:history_id, :history)
  Profile = Data.define(:history_id)

  setup do
    @connection = email_connections(:paid_jar_gmail)
    @connection.update!(
      inbound_cursor: "100",
      last_inbound_synced_at: Time.current
    )
  end

  test "incremental sync reads messagesAdded, deduplicates, and checkpoints after receipts" do
    mailbox = FakeMailbox.new(
      history_pages: [
        Page.new(
          history_id: "101",
          history: [
            History.new(
              id: "1001",
              messages_added: [
                Addition.new(Message.new(id: "gmail-1", thread_id: "thread-1")),
                Addition.new(Message.new(id: "gmail-1", thread_id: "thread-1"))
              ]
            )
          ]
        ),
        Page.new(
          history_id: "102",
          history: [
            History.new(
              id: "1002",
              messages_added: [ Addition.new(Message.new(id: "gmail-2", thread_id: "thread-2")) ]
            )
          ]
        )
      ]
    )

    assert_enqueued_jobs 2, only: EmailMessageReceipts::ProcessJob do
      EmailConnection::Gmail::Synchronizer.call(@connection, mailbox:)
    end

    assert_equal "100", mailbox.history_start
    assert_equal %w[gmail-1 gmail-2], @connection.email_message_receipts.order(:provider_message_id).pluck(:provider_message_id)
    assert_equal [ @connection.provider_account_id ],
      @connection.email_message_receipts.distinct.pluck(:provider_account_id)
    assert_equal "102", @connection.reload.inbound_cursor
    assert @connection.last_inbound_synced_at
  end

  test "initial sync uses seven days and catches history after the baseline" do
    @connection.update!(last_inbound_synced_at: nil)
    mailbox = FakeMailbox.new(
      listed_messages: [ Message.new(id: "listed", thread_id: "thread-listed") ],
      history_pages: [
        Page.new(
          history_id: "105",
          history: [
            History.new(
              id: "1005",
              messages_added: [ Addition.new(Message.new(id: "arrived", thread_id: "thread-arrived")) ]
            )
          ]
        )
      ]
    )

    freeze_time do
      EmailConnection::Gmail::Synchronizer.call(@connection, mailbox:)
      assert_in_delta 7.days.ago, mailbox.listed_since, 1.second
    end

    assert_equal "100", mailbox.history_start
    assert_equal %w[arrived listed], @connection.email_message_receipts.order(:provider_message_id).pluck(:provider_message_id)
    assert_equal "105", @connection.reload.inbound_cursor
  end

  test "a partial listing failure leaves the cursor unchanged and keeps earlier receipts" do
    mailbox = FakeMailbox.new(
      history_pages: [
        Page.new(
          history_id: "110",
          history: [
            History.new(
              id: "1010",
              messages_added: [
                Addition.new(Message.new(id: "saved-first", thread_id: "thread-1"))
              ]
            )
          ]
        )
      ],
      history_error: RuntimeError.new("listing failed")
    )

    assert_raises RuntimeError do
      EmailConnection::Gmail::Synchronizer.call(@connection, mailbox:)
    end

    assert_equal "100", @connection.reload.inbound_cursor
    assert @connection.email_message_receipts.exists?(provider_message_id: "saved-first")
  end

  test "expired history performs an overlapped recovery scan and catch-up" do
    last_synced_at = 2.days.ago.change(usec: 0)
    @connection.update!(last_inbound_synced_at: last_synced_at)
    catch_up = Page.new(
      history_id: "205",
      history: [
        History.new(
          id: "2005",
          messages_added: [ Addition.new(Message.new(id: "catch-up", thread_id: "thread-catch-up")) ]
        )
      ]
    )
    mailbox = ExpiredMailbox.new(
      old_cursor: "100",
      baseline_cursor: "200",
      listed_messages: [ Message.new(id: "recovered", thread_id: "thread-recovered") ],
      catch_up_page: catch_up
    )

    EmailConnection::Gmail::Synchronizer.call(@connection, mailbox:)

    assert_equal last_synced_at - 1.hour, mailbox.listed_since
    assert_equal %w[100 200], mailbox.history_starts
    assert_equal %w[catch-up recovered], @connection.email_message_receipts.order(:provider_message_id).pluck(:provider_message_id)
    assert_equal "205", @connection.reload.inbound_cursor
  end

  test "compare and swap prevents an older sync from overwriting a newer cursor" do
    page = Page.new(
      history_id: "101",
      history: [
        History.new(
          id: "1001",
          messages_added: [ Addition.new(Message.new(id: "stale-message", thread_id: "stale-thread")) ]
        )
      ]
    )
    mailbox = FakeMailbox.new(history_pages: [ page ]) do
      @connection.update_column(:inbound_cursor, "newer-cursor")
    end

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      EmailConnection::Gmail::Synchronizer.call(@connection, mailbox:)
    end

    assert_equal "newer-cursor", @connection.reload.inbound_cursor
    stale_receipt = @connection.email_message_receipts.find_by!(provider_message_id: "stale-message")
    assert_predicate stale_receipt, :status_pending?
  end

  test "identity replacement during a sync never enqueues old mailbox receipts" do
    original_identity = @connection.provider_account_id
    page = Page.new(
      history_id: "101",
      history: [
        History.new(
          id: "1001",
          messages_added: [ Addition.new(Message.new(id: "old-mailbox-message", thread_id: "old-thread")) ]
        )
      ]
    )
    mailbox = FakeMailbox.new(history_pages: [ page ]) do
      @connection.update_columns(
        provider_account_id: "replacement-google-account",
        inbound_cursor: "replacement-cursor"
      )
    end

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      EmailConnection::Gmail::Synchronizer.call(@connection, mailbox:)
    end

    receipt = @connection.email_message_receipts.find_by!(provider_message_id: "old-mailbox-message")
    assert_equal original_identity, receipt.provider_account_id
    assert_predicate receipt, :status_ignored?
    assert_equal "mailbox_replaced", receipt.metadata.fetch("reason")
  end

  test "credential replacement during a sync never enqueues the old generation" do
    original_generation = @connection.credential_generation
    page = Page.new(
      history_id: "101",
      history: [
        History.new(
          id: "1001",
          messages_added: [
            Addition.new(Message.new(id: "old-credential-message", thread_id: "old-thread"))
          ]
        )
      ]
    )
    mailbox = FakeMailbox.new(history_pages: [ page ]) do
      @connection.update_columns(
        credential_generation: original_generation + 1,
        inbound_cursor: "replacement-cursor"
      )
    end

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      EmailConnection::Gmail::Synchronizer.call(@connection, mailbox:)
    end

    receipt = @connection.email_message_receipts.find_by!(
      provider_message_id: "old-credential-message"
    )
    assert_equal original_generation, receipt.email_connection_generation
    assert_predicate receipt, :status_ignored?
    assert_equal "credentials_replaced", receipt.metadata.fetch("reason")
  end

  test "an old sync cannot retire a receipt already rebound to the current generation" do
    original_generation = @connection.credential_generation
    page = Page.new(
      history_id: "101",
      history: [
        History.new(
          id: "1001",
          messages_added: [
            Addition.new(Message.new(id: "rebound-message", thread_id: "rebound-thread"))
          ]
        )
      ]
    )
    mailbox = FakeMailbox.new(history_pages: [ page ]) do
      @connection.update_columns(
        credential_generation: original_generation + 1,
        inbound_cursor: "replacement-cursor"
      )
      receipt = @connection.email_message_receipts.find_by!(
        provider_message_id: "rebound-message"
      )
      receipt.rebind_unprocessed_to_generation!(
        generation: @connection.credential_generation
      )
    end

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      EmailConnection::Gmail::Synchronizer.call(
        @connection,
        mailbox:,
        credential_generation: original_generation
      )
    end

    receipt = @connection.email_message_receipts.find_by!(
      provider_message_id: "rebound-message"
    )
    assert_predicate receipt, :status_pending?
    assert_equal @connection.credential_generation, receipt.email_connection_generation
    assert_empty receipt.metadata
  end

  test "the current sync adopts an unprocessed receipt inserted by a stale sync" do
    original_generation = @connection.credential_generation
    page = Page.new(
      history_id: "101",
      history: [
        History.new(
          id: "1001",
          messages_added: [
            Addition.new(Message.new(id: "late-stale-message", thread_id: "stale-thread"))
          ]
        )
      ]
    )
    stale_mailbox = FakeMailbox.new(
      history_pages: [ page ],
      before_history: -> {
        @connection.update_columns(
          credential_generation: original_generation + 1,
          inbound_cursor: "replacement-cursor"
        )
      }
    )

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      EmailConnection::Gmail::Synchronizer.call(
        @connection,
        mailbox: stale_mailbox,
        credential_generation: original_generation
      )
    end

    stale_receipt = @connection.email_message_receipts.find_by!(
      provider_message_id: "late-stale-message"
    )
    assert_equal original_generation, stale_receipt.email_connection_generation
    assert_not stale_receipt.current_mailbox?

    current_mailbox = FakeMailbox.new(history_pages: [ page ])
    assert_enqueued_jobs 1, only: EmailMessageReceipts::ProcessJob do
      EmailConnection::Gmail::Synchronizer.call(@connection, mailbox: current_mailbox)
    end

    assert_predicate stale_receipt.reload, :status_pending?
    assert_equal @connection.credential_generation, stale_receipt.email_connection_generation
    assert stale_receipt.current_mailbox?
  end

  private
    class FakeMailbox
      attr_reader :history_start, :listed_since

      def initialize(
        history_pages: [],
        listed_messages: [],
        profile_history_id: "200",
        history_error: nil,
        before_history: nil,
        &after_history
      )
        @history_pages = history_pages
        @listed_messages = listed_messages
        @profile_history_id = profile_history_id
        @history_error = history_error
        @before_history = before_history
        @after_history = after_history
      end

      def profile
        Profile.new(history_id: @profile_history_id)
      end

      def each_history_page(start_history_id:)
        @history_start = start_history_id
        @before_history&.call
        @history_pages.each { |page| yield page }
        @after_history&.call
        raise @history_error if @history_error
      end

      def each_message_since(time:)
        @listed_since = time
        @listed_messages.each { |message| yield message }
      end
    end


    class ExpiredMailbox
      attr_reader :history_starts, :listed_since

      def initialize(old_cursor:, baseline_cursor:, listed_messages:, catch_up_page:)
        @old_cursor = old_cursor
        @baseline_cursor = baseline_cursor
        @listed_messages = listed_messages
        @catch_up_page = catch_up_page
        @history_starts = []
      end

      def profile
        Profile.new(history_id: @baseline_cursor)
      end

      def each_history_page(start_history_id:)
        history_starts << start_history_id
        if start_history_id == @old_cursor
          raise EmailConnection::Errors::HistoryExpired, "expired"
        end

        yield @catch_up_page
      end

      def each_message_since(time:)
        @listed_since = time
        @listed_messages.each { |message| yield message }
      end
    end
end
