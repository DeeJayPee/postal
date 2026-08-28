# frozen_string_literal: true

class SMTPQueueActivityBucket < ApplicationRecord

  REST_QUEUE_NAME = "Rest"

  COUNTER_COLUMNS = %w[
    attempted_count
    sent_count
    soft_fail_count
    hard_fail_count
    connect_error_count
    rate_limited_count
    backoff_matched_count
  ].freeze

  validates :queue_name, :bucket_started_at, presence: true

  scope :recent_first, -> { order(bucket_started_at: :desc) }

  class << self

    def record_result!(queue_name:, result:, occurred_at: Time.current)
      return if queue_name.blank? || result.nil?

      increments = counters_for(result)
      timestamp = occurred_at.change(sec: 0)
      connection = self.connection
      quoted_columns = %w[queue_name bucket_started_at].concat(COUNTER_COLUMNS).push("created_at", "updated_at")
      quoted_values = [queue_name, timestamp]
                      .concat(COUNTER_COLUMNS.map { |column| increments.fetch(column) })
                      .push(occurred_at, occurred_at)
                      .map { |value| connection.quote(value) }
      updates = COUNTER_COLUMNS.map do |column|
        quoted = connection.quote_column_name(column)
        "#{quoted} = #{quoted} + VALUES(#{quoted})"
      end
      updates << "updated_at = VALUES(updated_at)"

      connection.execute(<<~SQL.squish)
        INSERT INTO #{connection.quote_table_name(table_name)}
          (#{quoted_columns.map { |column| connection.quote_column_name(column) }.join(', ')})
        VALUES (#{quoted_values.join(', ')})
        ON DUPLICATE KEY UPDATE #{updates.join(', ')}
      SQL
    rescue StandardError => e
      Postal.logger.error "Could not record SMTP queue activity: #{e.class}: #{e.message}", queue: queue_name
      nil
    end

    def prune_before!(cutoff, batch_size: 1_000)
      deleted = 0
      where("bucket_started_at < ?", cutoff).in_batches(of: batch_size) do |buckets|
        deleted += buckets.delete_all
      end
      deleted
    end

    private

    def counters_for(result)
      counters = COUNTER_COLUMNS.index_with { 0 }
      counters["attempted_count"] = 1
      counters["sent_count"] = 1 if result.type == "Sent"
      counters["soft_fail_count"] = 1 if result.type == "SoftFail"
      counters["hard_fail_count"] = 1 if result.type == "HardFail"
      counters["connect_error_count"] = 1 if result.connect_error
      counters["rate_limited_count"] = 1 if result.rate_limited
      counters["backoff_matched_count"] = 1 if result.backoff_matched
      counters
    end

  end

end
