class CreatePlatformAdminEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :platform_admin_events do |t|
      t.references :actor_identity,
        null: true,
        foreign_key: { to_table: :identities, on_delete: :nullify }
      t.references :account,
        null: true,
        foreign_key: { on_delete: :nullify }
      t.string :actor_email_address, null: false
      t.string :action, null: false
      t.string :target_type
      t.bigint :target_id
      t.json :metadata, null: false
      t.timestamps
    end

    add_index :platform_admin_events, %i[target_type target_id]
    add_index :platform_admin_events, %i[action created_at]
  end
end
