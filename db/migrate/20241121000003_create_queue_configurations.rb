# frozen_string_literal: true

class CreateQueueConfigurations < ActiveRecord::Migration[7.0]
  def change
    create_table :queue_configurations do |t|
      t.string :queue_name, null: false
      t.integer :min_smtp_out, default: 1
      t.integer :max_smtp_out, default: 1
      t.integer :max_rcpt_per_message, default: 100
      t.integer :max_msg_rate_per_hour
      t.integer :max_conn_rate_per_hour
      t.boolean :enabled, default: true
      t.text :description
      t.timestamps
    end

    add_index :queue_configurations, :queue_name, unique: true
  end
end
