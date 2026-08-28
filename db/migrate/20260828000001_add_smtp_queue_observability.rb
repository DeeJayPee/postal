# frozen_string_literal: true

class AddSMTPQueueObservability < ActiveRecord::Migration[7.0]

  def change
    create_table :smtp_queue_events do |t|
      t.integer :queue_configuration_id
      t.string :queue_name, null: false
      t.string :event_type, null: false
      t.string :category
      t.string :source, null: false
      t.string :severity, null: false
      t.datetime :first_occurred_at, null: false
      t.datetime :last_occurred_at, null: false
      t.integer :occurrence_count, null: false, default: 1
      t.string :fingerprint
      t.datetime :bucket_started_at
      t.integer :backoff_rule_id
      t.text :rule_pattern
      t.text :smtp_response
      t.text :details
      t.string :domain
      t.string :source_ip
      t.string :remote_endpoint
      t.string :log_id
      t.integer :queued_message_id
      t.integer :message_id
      t.integer :server_id
      t.integer :actor_id
      t.datetime :retry_at
      t.timestamps
    end

    add_index :smtp_queue_events, [:queue_name, :last_occurred_at], name: "idx_smtp_queue_events_queue_time"
    add_index :smtp_queue_events, [:queue_name, :event_type, :last_occurred_at], name: "idx_smtp_queue_events_queue_type_time"
    add_index :smtp_queue_events, :queue_configuration_id
    add_index :smtp_queue_events, :backoff_rule_id
    add_index :smtp_queue_events, :actor_id
    add_index :smtp_queue_events,
              [:queue_configuration_id, :event_type, :fingerprint, :bucket_started_at],
              unique: true,
              name: "idx_smtp_queue_events_dedup"

    create_table :smtp_queue_activity_buckets do |t|
      t.string :queue_name, null: false
      t.datetime :bucket_started_at, null: false
      t.bigint :attempted_count, null: false, default: 0
      t.bigint :sent_count, null: false, default: 0
      t.bigint :soft_fail_count, null: false, default: 0
      t.bigint :hard_fail_count, null: false, default: 0
      t.bigint :connect_error_count, null: false, default: 0
      t.bigint :rate_limited_count, null: false, default: 0
      t.bigint :backoff_matched_count, null: false, default: 0
      t.timestamps
    end

    add_index :smtp_queue_activity_buckets,
              [:queue_name, :bucket_started_at],
              unique: true,
              name: "idx_smtp_queue_activity_queue_bucket"
    add_index :smtp_queue_activity_buckets, :bucket_started_at

    add_index :queued_messages,
              [:virtual_queue, :domain],
              name: "idx_queued_messages_virtual_queue_domain"
  end

end
