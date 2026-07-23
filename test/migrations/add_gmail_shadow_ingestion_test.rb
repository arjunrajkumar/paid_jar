require "test_helper"
require Rails.root.join("db/migrate/20260722160000_add_gmail_shadow_ingestion")

class AddGmailShadowIngestionTest < ActiveSupport::TestCase
  test "is explicitly irreversible" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      AddGmailShadowIngestion.new.down
    end

    assert_includes error.message, "mailbox-scoped message identifiers"
  end

  test "uses a status-first index for globally due receipts" do
    index = ActiveRecord::Base.connection
      .indexes(:email_message_receipts)
      .find { |candidate| candidate.name == "index_email_receipts_for_retry" }

    assert_equal %w[status next_retry_at id], index.columns
  end

  test "requires receipt credential generations without a misleading database default" do
    column = EmailMessageReceipt.columns_hash.fetch("email_connection_generation")

    assert_not column.null
    assert_nil column.default
  end
end
