# frozen_string_literal: true

class AddRateLimitingToQueueConfigurations < ActiveRecord::Migration[7.0]
  def change
    add_column :queue_configurations, :max_msg_rate, :string
    add_column :queue_configurations, :backoff_reroute_to, :string
  end
end
