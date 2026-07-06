class CreateAccountingIntegrationsAndInvoices < ActiveRecord::Migration[8.1]
  def up
    drop_xero_connections
    rename_invoice_integrations
    create_invoices
  end

  def down
    drop_table :invoices if table_exists?(:invoices)

    if table_exists?(:accounting_integrations)
      remove_index :accounting_integrations, column: [ :account_id, :provider ] if index_exists?(:accounting_integrations, [ :account_id, :provider ])
      remove_index :accounting_integrations, column: [ :account_id, :provider, :external_account_id ] if index_exists?(:accounting_integrations, [ :account_id, :provider, :external_account_id ])
      remove_index :accounting_integrations, column: [ :provider, :status ] if index_exists?(:accounting_integrations, [ :provider, :status ])

      rename_table :accounting_integrations, :invoice_integrations

      add_index :invoice_integrations, [ :account_id, :provider, :external_account_id ], unique: true
      add_index :invoice_integrations, [ :provider, :status ]
    end

    create_xero_connections unless table_exists?(:xero_connections)
  end

  private
    def drop_xero_connections
      return unless table_exists?(:xero_connections)

      drop_table :xero_connections do |t|
        t.string :xero_user_id
        t.string :email
        t.string :tenant_id
        t.string :tenant_name
        t.text :access_token, null: false
        t.text :refresh_token, null: false
        t.text :id_token
        t.string :token_type, null: false
        t.json :scopes, null: false, default: []
        t.datetime :expires_at, null: false
        t.json :connections, null: false, default: []
        t.json :raw_token_set, null: false, default: {}
        t.json :raw_userinfo, null: false, default: {}
        t.timestamps
      end
    end

    def rename_invoice_integrations
      return unless table_exists?(:invoice_integrations)

      remove_index :invoice_integrations, column: [ :account_id, :provider, :external_account_id ] if index_exists?(:invoice_integrations, [ :account_id, :provider, :external_account_id ])
      remove_index :invoice_integrations, column: [ :provider, :status ] if index_exists?(:invoice_integrations, [ :provider, :status ])

      rename_table :invoice_integrations, :accounting_integrations

      add_index :accounting_integrations, [ :account_id, :provider ], unique: true
      add_index :accounting_integrations, [ :provider, :status ]
    end

    def create_invoices
      create_table :invoices do |t|
        t.references :account, null: false, foreign_key: true
        t.references :accounting_integration, null: false, foreign_key: true
        t.string :external_id, null: false
        t.string :number
        t.string :invoice_type
        t.string :status
        t.string :currency
        t.decimal :amount_due, precision: 12, scale: 2
        t.decimal :amount_paid, precision: 12, scale: 2
        t.decimal :total, precision: 12, scale: 2
        t.date :issued_on
        t.date :due_on
        t.string :contact_external_id
        t.string :contact_name
        t.json :provider_data, null: false, default: {}
        t.json :raw_data, null: false, default: {}
        t.datetime :synced_at

        t.timestamps
      end

      add_index :invoices, [ :accounting_integration_id, :external_id ], unique: true
      add_index :invoices, [ :account_id, :status ]
      add_index :invoices, :due_on
    end

    def create_xero_connections
      create_table :xero_connections do |t|
        t.string :xero_user_id
        t.string :email
        t.string :tenant_id
        t.string :tenant_name
        t.text :access_token, null: false
        t.text :refresh_token, null: false
        t.text :id_token
        t.string :token_type, null: false
        t.json :scopes, null: false, default: []
        t.datetime :expires_at, null: false
        t.json :connections, null: false, default: []
        t.json :raw_token_set, null: false, default: {}
        t.json :raw_userinfo, null: false, default: {}

        t.timestamps
      end

      add_index :xero_connections, :tenant_id
      add_index :xero_connections, :xero_user_id
    end
end
