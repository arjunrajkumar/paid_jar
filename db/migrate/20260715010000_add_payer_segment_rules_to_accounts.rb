class AddPayerSegmentRulesToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :payer_segment_minimum_payment_history, :integer, null: false, default: 3
    add_column :accounts, :payer_segment_minimum_unreliable_history, :integer, null: false, default: 5
    add_column :accounts, :payer_segment_pays_on_time_rate, :integer, null: false, default: 80
    add_column :accounts, :payer_segment_unreliable_on_time_rate, :integer, null: false, default: 50
    add_column :accounts, :payer_segment_slow_payer_days, :integer, null: false, default: 7
  end
end
