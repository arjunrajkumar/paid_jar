class CreateStripeInstallationClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :stripe_installation_claims do |t|
      t.references :account, null: true, foreign_key: { on_delete: :nullify }
      t.string :token_digest, null: false, limit: 64
      t.string :request_digest, null: false, limit: 64
      t.string :stripe_account_id, null: false
      t.string :stripe_user_id, null: false
      t.boolean :livemode, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :stripe_installation_claims, :token_digest, unique: true
    add_index :stripe_installation_claims, :request_digest, unique: true
    add_index :stripe_installation_claims, [ :stripe_account_id, :livemode ]
    add_index :stripe_installation_claims, :expires_at
  end
end
