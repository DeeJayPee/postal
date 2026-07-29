# frozen_string_literal: true

class AddSMTPQueueScheduler < ActiveRecord::Migration[7.0]
  def change
    change_table :queue_configurations, bulk: true do |t|
      t.integer :backoff_max_smtp_out, default: 1, null: false
      t.string :retry_after, default: "10m", null: false
      t.string :backoff_retry_after, default: "1h", null: false
      t.integer :max_msg_per_connection, default: 20, null: false
      t.integer :mx_connection_attempts, default: 2, null: false
    end

    create_table :smtp_queue_states do |t|
      t.string :queue_key, null: false
      t.string :virtual_queue
      t.string :domain
      t.string :batch_key
      t.datetime :next_attempt_at
      t.datetime :last_dispatched_at
      t.integer :consecutive_failures, default: 0, null: false
      t.datetime :rate_window_started_at
      t.integer :rate_attempts, default: 0, null: false
      t.text :last_error
      t.timestamps
    end

    add_index :smtp_queue_states, :queue_key, unique: true
    add_index :smtp_queue_states, [:next_attempt_at, :last_dispatched_at], name: "idx_smtp_queue_states_dispatch"

    create_table :smtp_queue_leases do |t|
      t.references :smtp_queue_state, null: false, foreign_key: true
      t.integer :queued_message_id, null: false
      t.string :locker, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :smtp_queue_leases, :queued_message_id, unique: true
    add_index :smtp_queue_leases, [:smtp_queue_state_id, :expires_at], name: "idx_smtp_queue_leases_active"
    add_index :smtp_queue_leases, :expires_at

    add_index :queued_messages,
              [:virtual_queue, :locked_at, :retry_after, :created_at],
              name: "idx_queued_messages_virtual_dispatch"
    add_index :queued_messages,
              [:domain, :locked_at, :retry_after, :created_at],
              name: "idx_queued_messages_domain_dispatch"
    add_index :queued_messages,
              [:batch_key, :locked_at, :retry_after, :created_at],
              name: "idx_queued_messages_batch_dispatch"
    add_index :queued_messages, :locked_by, name: "idx_queued_messages_locker"
  end
end
