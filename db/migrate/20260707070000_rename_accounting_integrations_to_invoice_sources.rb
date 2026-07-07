class RenameAccountingIntegrationsToInvoiceSources < ActiveRecord::Migration[8.1]
  def change
    rename_table :accounting_integrations, :invoice_sources
    rename_column :invoices, :accounting_integration_id, :invoice_source_id
  end
end
