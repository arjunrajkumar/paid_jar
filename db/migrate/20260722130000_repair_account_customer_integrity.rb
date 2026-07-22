class RepairAccountCustomerIntegrity < ActiveRecord::Migration[8.1]
  DEFAULT_SEGMENTS = {
    "good_debtor" => 80,
    "normal_debtor" => nil,
    "bad_debtor" => 50
  }.freeze

  ORPHAN_CUSTOMER_SEGMENT_COLUMNS = %i[
    minimum_payment_history
    typical_delay_days
  ].freeze

  class MigrationAccount < ActiveRecord::Base
    self.table_name = "accounts"
  end

  class MigrationCustomer < ActiveRecord::Base
    self.table_name = "customers"
  end

  class MigrationCustomerSegment < ActiveRecord::Base
    self.table_name = "customer_segments"
  end

  class MigrationInvoice < ActiveRecord::Base
    self.table_name = "invoices"
  end

  class MigrationInvoiceSource < ActiveRecord::Base
    self.table_name = "invoice_sources"
  end

  def up
    ensure_default_customer_segments
    repair_customer_segment_references
    remove_orphan_customer_segment_columns
    backfill_account_external_ids
    backfill_invoice_customers
    enforce_required_references
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Repaired identifiers and customer associations cannot be restored to their previous invalid state"
  end

  private
    def ensure_default_customer_segments
      MigrationAccount.reset_column_information
      MigrationCustomerSegment.reset_column_information

      MigrationAccount.in_batches(of: 500) do |accounts|
        account_ids = accounts.ids
        existing_keys = MigrationCustomerSegment
          .where(account_id: account_ids)
          .pluck(:account_id, :payer_segment)
          .to_set
        now = Time.current
        rows = account_ids.flat_map do |account_id|
          DEFAULT_SEGMENTS.filter_map do |payer_segment, on_time_rate|
            next if existing_keys.include?([ account_id, payer_segment ])

            {
              account_id:,
              payer_segment:,
              on_time_rate:,
              created_at: now,
              updated_at: now
            }
          end
        end

        MigrationCustomerSegment.insert_all(rows) if rows.any?
      end

      MigrationCustomerSegment.where(payer_segment: "good_debtor", on_time_rate: nil).update_all(on_time_rate: 80)
      MigrationCustomerSegment.where(payer_segment: "bad_debtor", on_time_rate: nil).update_all(on_time_rate: 50)
      MigrationCustomerSegment.where(payer_segment: "normal_debtor").where.not(on_time_rate: nil).update_all(on_time_rate: nil)

      verify_customer_segment_sets
    end

    def verify_customer_segment_sets
      unsupported_count = MigrationCustomerSegment.where.not(payer_segment: DEFAULT_SEGMENTS.keys).count
      if unsupported_count.positive?
        raise ActiveRecord::MigrationError,
          "Cannot repair customer segments: #{unsupported_count} rows use an unsupported payer segment"
      end

      invalid_account_count = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM (
          SELECT accounts.id
          FROM accounts
          LEFT JOIN customer_segments
            ON customer_segments.account_id = accounts.id
          GROUP BY accounts.id
          HAVING COUNT(customer_segments.id) <> 3
        ) invalid_customer_segment_accounts
      SQL
      if invalid_account_count.positive?
        raise ActiveRecord::MigrationError,
          "Cannot repair customer segments: #{invalid_account_count} accounts do not have exactly three segments"
      end
    end

    def repair_customer_segment_references
      execute <<~SQL.squish
        UPDATE customers
        INNER JOIN customer_segments current_segment
          ON current_segment.id = customers.customer_segment_id
        INNER JOIN customer_segments corrected_segment
          ON corrected_segment.account_id = customers.account_id
          AND corrected_segment.payer_segment = current_segment.payer_segment
        SET customers.customer_segment_id = corrected_segment.id
        WHERE current_segment.account_id <> customers.account_id
      SQL

      execute <<~SQL.squish
        UPDATE customers
        INNER JOIN customer_segments
          ON customer_segments.account_id = customers.account_id
          AND customer_segments.payer_segment = 'normal_debtor'
        SET customers.customer_segment_id = customer_segments.id
        WHERE customers.customer_segment_id IS NULL
      SQL
    end

    def remove_orphan_customer_segment_columns
      ORPHAN_CUSTOMER_SEGMENT_COLUMNS.each do |column|
        remove_column :customer_segments, column if column_exists?(:customer_segments, column)
      end
    end

    def backfill_account_external_ids
      MigrationAccount.reset_column_information

      highest_account_id = MigrationAccount.maximum(:external_account_id).to_i
      sequence_value = if table_exists?(:account_external_id_sequences)
        select_value("SELECT MAX(value) FROM account_external_id_sequences").to_i
      else
        0
      end
      next_external_id = [ highest_account_id, sequence_value ].max

      MigrationAccount.where(external_account_id: nil).find_each do |account|
        next_external_id += 1
        account.update_columns(external_account_id: next_external_id)
      end

      reset_external_id_sequence(next_external_id)
    end

    def reset_external_id_sequence(value)
      return unless table_exists?(:account_external_id_sequences)

      execute "DELETE FROM account_external_id_sequences"
      execute <<~SQL.squish
        INSERT INTO account_external_id_sequences (value)
        VALUES (#{connection.quote(value)})
      SQL
    end

    def backfill_invoice_customers
      MigrationCustomer.reset_column_information
      MigrationInvoice.reset_column_information
      MigrationInvoiceSource.reset_column_information
      normal_segments = MigrationCustomerSegment
        .where(payer_segment: "normal_debtor")
        .pluck(:account_id, :id)
        .to_h

      MigrationInvoice.where(customer_id: nil).find_each do |invoice|
        verify_invoice_source_account!(invoice)
        customer = customer_for(invoice, normal_segment_id: normal_segments.fetch(invoice.account_id))
        invoice.update_columns(customer_id: customer.id)
      end
    end

    def verify_invoice_source_account!(invoice)
      source_account_id = MigrationInvoiceSource.where(id: invoice.invoice_source_id).pick(:account_id)
      return if source_account_id == invoice.account_id

      raise ActiveRecord::MigrationError,
        "Cannot backfill invoice #{invoice.id}: its invoice source belongs to another account"
    end

    def customer_for(invoice, normal_segment_id:)
      external_id = invoice.contact_external_id.presence || "invoice:#{invoice.external_id}"
      customer = MigrationCustomer.find_or_initialize_by(
        invoice_source_id: invoice.invoice_source_id,
        external_id:
      )

      if customer.persisted? && customer.account_id != invoice.account_id
        raise ActiveRecord::MigrationError,
          "Cannot backfill invoice #{invoice.id}: its provider customer belongs to another account"
      end

      customer.assign_attributes(
        account_id: invoice.account_id,
        customer_segment_id: customer.customer_segment_id || normal_segment_id,
        name: customer.name.presence || customer_name_for(invoice, external_id:),
        email: customer.email.presence || customer_email_for(invoice),
        details_observed_at: customer.details_observed_at || invoice.issued_on
      )
      customer.save!
      customer
    end

    def customer_name_for(invoice, external_id:)
      invoice.contact_name.presence ||
        invoice.raw_data.to_h.dig("Contact", "Name").presence ||
        customer_email_for(invoice).presence ||
        external_id
    end

    def customer_email_for(invoice)
      invoice.provider_data.to_h["customer_email"].presence ||
        invoice.raw_data.to_h.dig("Contact", "EmailAddress").presence
    end

    def enforce_required_references
      ensure_no_nulls!(:customers, :customer_segment_id)
      ensure_no_nulls!(:accounts, :external_account_id)
      ensure_no_nulls!(:invoices, :customer_id)

      change_column_null :customers, :customer_segment_id, false if column_allows_null?(:customers, :customer_segment_id)
      change_column_null :accounts, :external_account_id, false if column_allows_null?(:accounts, :external_account_id)
      change_column_null :invoices, :customer_id, false if column_allows_null?(:invoices, :customer_id)
    end

    def ensure_no_nulls!(table, column)
      missing_count = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM #{connection.quote_table_name(table)}
        WHERE #{connection.quote_column_name(column)} IS NULL
      SQL
      return if missing_count.zero?

      raise ActiveRecord::MigrationError,
        "Cannot enforce #{table}.#{column}: #{missing_count} rows are still missing a value"
    end

    def column_allows_null?(table, column)
      connection.schema_cache.clear!
      connection.columns(table).find { |candidate| candidate.name == column.to_s }.null
    end
end
