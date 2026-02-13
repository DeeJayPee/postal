# frozen_string_literal: true

class AddBackoffStateToQueueConfigurations < ActiveRecord::Migration[7.0]
  def change
    change_table :queue_configurations, bulk: true do |t|
      t.string :mode, default: "normal", null: false
      t.integer :backoff_base_delay_seconds, default: 2.hours.to_i, null: false
      t.integer :backoff_auto_success_threshold
      t.integer :backoff_auto_success_window_seconds
      t.integer :backoff_success_count, default: 0, null: false
      t.datetime :backoff_started_at
      t.datetime :backoff_last_success_at
    end

    add_index :queue_configurations, :mode
  end
end
