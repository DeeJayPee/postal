# frozen_string_literal: true

class CreateBackoffRules < ActiveRecord::Migration[7.0]
  def change
    create_table :backoff_rules do |t|
      t.string :pattern, null: false
      t.string :action, null: false
      t.boolean :enabled, default: true, null: false
      t.text :description
      t.timestamps
    end

    add_index :backoff_rules, :enabled
    add_index :backoff_rules, [:pattern, :action], unique: true
  end
end
