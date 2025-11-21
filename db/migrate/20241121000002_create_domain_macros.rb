# frozen_string_literal: true

class CreateDomainMacros < ActiveRecord::Migration[7.0]
  def change
    create_table :domain_macros do |t|
      t.string :name, null: false
      t.text :domains, null: false # Comma-separated list of domains
      t.string :queue_name
      t.boolean :enabled, default: true
      t.timestamps
    end

    add_index :domain_macros, :name, unique: true
  end
end
