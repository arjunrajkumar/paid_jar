class CreateCustomerSegments < ActiveRecord::Migration[8.1]
  DEFAULT_SEGMENTS = {
    "good_debtor" => 80,
    "normal_debtor" => nil,
    "bad_debtor" => 50
  }.freeze

  LEGACY_SEGMENTS = {
    "pays_on_time" => "good_debtor",
    "slow_payer" => "bad_debtor",
    "unreliable_payer" => "bad_debtor"
  }.freeze

  LEGACY_ACCOUNT_RULE_COLUMNS = %i[
    payer_segment_minimum_payment_history
    payer_segment_minimum_unreliable_history
    payer_segment_pays_on_time_rate
    payer_segment_unreliable_on_time_rate
    payer_segment_slow_payer_days
  ].freeze

  class MigrationAccount < ActiveRecord::Base
    self.table_name = "accounts"
  end

  class MigrationCustomerSegment < ActiveRecord::Base
    self.table_name = "customer_segments"
  end

  def up
    ensure_customer_segments_table
    ensure_default_customer_segments
    ensure_customer_segment_reference
    backfill_customer_segment_references
    enforce_customer_segment_reference
    remove_legacy_segmentation_columns
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Customer segment configuration is not restored by this migration"
  end

  private
    def ensure_customer_segments_table
      unless table_exists?(:customer_segments)
        create_table :customer_segments do |t|
          t.references :account, null: false, foreign_key: true
          t.string :payer_segment, null: false
          t.integer :on_time_rate
          t.timestamps
        end
      end

      unless index_exists?(:customer_segments, %i[account_id payer_segment], unique: true)
        add_index :customer_segments, %i[account_id payer_segment], unique: true
      end
      unless foreign_key_exists?(:customer_segments, :accounts, column: :account_id)
        add_foreign_key :customer_segments, :accounts
      end
    end

    def ensure_default_customer_segments
      MigrationAccount.reset_column_information
      MigrationCustomerSegment.reset_column_information

      MigrationAccount.in_batches(of: 500) do |accounts|
        account_rows = accounts.to_a
        existing_keys = MigrationCustomerSegment
          .where(account_id: account_rows.map(&:id))
          .pluck(:account_id, :payer_segment)
          .to_set
        now = Time.current
        rows = account_rows.flat_map do |account|
          DEFAULT_SEGMENTS.filter_map do |payer_segment, default_on_time_rate|
            next if existing_keys.include?([ account.id, payer_segment ])

            {
              account_id: account.id,
              payer_segment:,
              on_time_rate: on_time_rate_for(account, payer_segment, default_on_time_rate),
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
    end

    def on_time_rate_for(account, payer_segment, default)
      legacy_attribute = case payer_segment
      when "good_debtor"
        "payer_segment_pays_on_time_rate"
      when "bad_debtor"
        "payer_segment_unreliable_on_time_rate"
      end

      return default unless legacy_attribute && account.has_attribute?(legacy_attribute)

      account[legacy_attribute] || default
    end

    def ensure_customer_segment_reference
      unless column_exists?(:customers, :customer_segment_id)
        add_reference :customers, :customer_segment, null: true, foreign_key: true
      end
      unless index_exists?(:customers, :customer_segment_id)
        add_index :customers, :customer_segment_id
      end
      unless foreign_key_exists?(:customers, :customer_segments, column: :customer_segment_id)
        add_foreign_key :customers, :customer_segments
      end
      unless index_exists?(:customers, %i[account_id customer_segment_id])
        add_index :customers, %i[account_id customer_segment_id]
      end
    end

    def backfill_customer_segment_references
      segment_expression = if column_exists?(:customers, :payer_segment)
        legacy_segment_expression
      else
        "'normal_debtor'"
      end

      execute <<~SQL.squish
        UPDATE customers
        INNER JOIN customer_segments
          ON customer_segments.account_id = customers.account_id
          AND customer_segments.payer_segment = #{segment_expression}
        SET customers.customer_segment_id = customer_segments.id
        WHERE customers.customer_segment_id IS NULL
      SQL
    end

    def legacy_segment_expression
      mappings = LEGACY_SEGMENTS.merge(
        "good_debtor" => "good_debtor",
        "bad_debtor" => "bad_debtor"
      )
      clauses = mappings.map do |legacy_segment, current_segment|
        "WHEN #{connection.quote(legacy_segment)} THEN #{connection.quote(current_segment)}"
      end.join(" ")

      "CASE customers.payer_segment #{clauses} ELSE 'normal_debtor' END"
    end

    def enforce_customer_segment_reference
      missing_count = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*)
        FROM customers
        WHERE customer_segment_id IS NULL
      SQL
      if missing_count.positive?
        raise ActiveRecord::MigrationError,
          "Cannot finish customer segment migration: #{missing_count} customers have no segment"
      end

      change_column_null :customers, :customer_segment_id, false if customer_segment_column.null
    end

    def customer_segment_column
      connection.schema_cache.clear!
      connection.columns(:customers).find { |column| column.name == "customer_segment_id" }
    end

    def remove_legacy_segmentation_columns
      if index_exists?(:customers, %i[account_id payer_segment])
        remove_index :customers, column: %i[account_id payer_segment]
      end
      remove_column :customers, :payer_segment if column_exists?(:customers, :payer_segment)

      LEGACY_ACCOUNT_RULE_COLUMNS.each do |column|
        remove_column :accounts, column if column_exists?(:accounts, column)
      end
    end
end
