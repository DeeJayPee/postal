# frozen_string_literal: true

class CreateMxRollups < ActiveRecord::Migration[7.0]
  def change
    create_table :mx_rollups do |t|
      t.string :mx_hostname, null: false
      t.string :rollup_name, null: false
      t.text :description
      t.boolean :enabled, default: true
      t.timestamps
    end

    add_index :mx_rollups, :mx_hostname
    add_index :mx_rollups, :rollup_name
  end
end
