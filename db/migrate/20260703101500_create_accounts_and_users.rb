class CreateAccountsAndUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :name, null: false

      t.timestamps
    end

    create_table :users do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :email, null: false

      t.timestamps
    end

    add_index :accounts, :name
    add_index :users, :email, unique: true
  end
end
