# frozen_string_literal: true

# == Schema Information
#
# Table name: queued_messages
#
#  id            :integer          not null, primary key
#  server_id     :integer
#  message_id    :integer
#  domain        :string(255)
#  locked_by     :string(255)
#  locked_at     :datetime
#  retry_after   :datetime
#  created_at    :datetime
#  updated_at    :datetime
#  ip_address_id :integer
#  attempts      :integer          default(0)
#  route_id      :integer
#  manual        :boolean          default(FALSE)
#  batch_key     :string(255)
#
# Indexes
#
#  index_queued_messages_on_domain      (domain)
#  index_queued_messages_on_message_id  (message_id)
#  index_queued_messages_on_server_id   (server_id)
#

class QueuedMessage < ApplicationRecord

  include HasMessage
  include HasLocking

  belongs_to :server
  belongs_to :ip_address, optional: true

  before_create :allocate_ip_address

  scope :ready_with_delayed_retry, -> { where("retry_after IS NULL OR retry_after < ?", 30.seconds.ago) }
  scope :with_stale_lock, -> { where("locked_at IS NOT NULL AND locked_at < ?", Postal::Config.postal.queued_message_lock_stale_days.days.ago) }

  def self.global_queue_summary(known_queue_names)
    total = count
    known = known_queue_names.present? ? where(virtual_queue: known_queue_names).count : 0

    {
      total: total,
      known: known,
      rest: total - known
    }
  end

  def self.runtime_summary(scope = all)
    quoted_threshold = connection.quote(30.seconds.ago)
    values = scope.pick(
      Arel.sql("COUNT(*)"),
      Arel.sql("COALESCE(SUM(CASE WHEN locked_at IS NULL AND (retry_after IS NULL OR retry_after < #{quoted_threshold}) THEN 1 ELSE 0 END), 0)"),
      Arel.sql("COALESCE(SUM(CASE WHEN locked_at IS NULL AND retry_after IS NOT NULL AND retry_after >= #{quoted_threshold} THEN 1 ELSE 0 END), 0)"),
      Arel.sql("COALESCE(SUM(CASE WHEN locked_at IS NOT NULL THEN 1 ELSE 0 END), 0)"),
      Arel.sql("MIN(CASE WHEN locked_at IS NULL AND retry_after IS NOT NULL AND retry_after >= #{quoted_threshold} THEN retry_after END)"),
      Arel.sql("MIN(created_at)")
    )

    {
      total: values[0].to_i,
      ready: values[1].to_i,
      scheduled: values[2].to_i,
      locked: values[3].to_i,
      next_attempt_at: cast_observability_time(values[4]),
      oldest_at: cast_observability_time(values[5])
    }
  end

  def self.domain_observability(scope = all, limit: 10)
    quoted_threshold = connection.quote(30.seconds.ago)
    scope.group(:domain)
         .order(Arel.sql("COUNT(*) DESC"))
         .limit(limit)
         .pluck(
           :domain,
           Arel.sql("COUNT(*)"),
           Arel.sql("COALESCE(SUM(CASE WHEN locked_at IS NULL AND (retry_after IS NULL OR retry_after < #{quoted_threshold}) THEN 1 ELSE 0 END), 0)"),
           Arel.sql("COALESCE(SUM(CASE WHEN locked_at IS NULL AND retry_after IS NOT NULL AND retry_after >= #{quoted_threshold} THEN 1 ELSE 0 END), 0)"),
           Arel.sql("MIN(created_at)")
         ).map do |domain, total, ready, scheduled, oldest_at|
      {
        domain: domain,
        total: total.to_i,
        ready: ready.to_i,
        scheduled: scheduled.to_i,
        oldest_at: cast_observability_time(oldest_at)
      }
    end
  end

  def self.runtime_by_virtual_queue(queue_names)
    scope = where(virtual_queue: queue_names)
    totals = scope.group(:virtual_queue).count
    locked = scope.where.not(locked_at: nil).group(:virtual_queue).count
    ready = scope.where(locked_at: nil).ready_with_delayed_retry.group(:virtual_queue).count
    scheduled_scope = scope.where(locked_at: nil)
                           .where("retry_after IS NOT NULL AND retry_after >= ?", 30.seconds.ago)
    scheduled = scheduled_scope.group(:virtual_queue).count
    next_attempts = scheduled_scope.group(:virtual_queue).minimum(:retry_after)
    oldest = scope.group(:virtual_queue).minimum(:created_at)

    queue_names.index_with do |queue_name|
      {
        total: totals[queue_name].to_i,
        ready: ready[queue_name].to_i,
        scheduled: scheduled[queue_name].to_i,
        locked: locked[queue_name].to_i,
        next_attempt_at: next_attempts[queue_name],
        oldest_at: oldest[queue_name]
      }
    end
  end

  # Builds the global, configured-queue, and Rest counters from one grouped
  # scan. This is used by the 30-second admin refresh path, where issuing a
  # separate COUNT/MIN query for every metric becomes expensive on large
  # backlogs.
  def self.observability_snapshot(known_queue_names)
    threshold = 30.seconds.ago
    quoted_threshold = connection.quote(threshold)
    rows = connection.select_all(<<~SQL.squish).to_a
      SELECT virtual_queue,
             COUNT(*) AS total_count,
             SUM(CASE WHEN locked_at IS NULL
                       AND (retry_after IS NULL OR retry_after < #{quoted_threshold})
                      THEN 1 ELSE 0 END) AS ready_count,
             SUM(CASE WHEN locked_at IS NULL
                       AND retry_after IS NOT NULL
                       AND retry_after >= #{quoted_threshold}
                      THEN 1 ELSE 0 END) AS scheduled_count,
             SUM(CASE WHEN locked_at IS NOT NULL THEN 1 ELSE 0 END) AS locked_count,
             MIN(CASE WHEN locked_at IS NULL
                       AND retry_after IS NOT NULL
                       AND retry_after >= #{quoted_threshold}
                      THEN retry_after END) AS next_attempt_at,
             MIN(created_at) AS oldest_at
        FROM #{connection.quote_table_name(table_name)}
       GROUP BY virtual_queue
    SQL

    names = known_queue_names.index_with(true)
    queues = known_queue_names.index_with { empty_observability_runtime }
    global = empty_observability_runtime
    rest = empty_observability_runtime

    rows.each do |row|
      runtime = {
        total: row.fetch("total_count").to_i,
        ready: row.fetch("ready_count").to_i,
        scheduled: row.fetch("scheduled_count").to_i,
        locked: row.fetch("locked_count").to_i,
        next_attempt_at: cast_observability_time(row["next_attempt_at"]),
        oldest_at: cast_observability_time(row["oldest_at"])
      }
      merge_observability_runtime!(global, runtime)
      if row["virtual_queue"].present? && names.key?(row["virtual_queue"])
        queues[row["virtual_queue"]] = runtime
      else
        merge_observability_runtime!(rest, runtime)
      end
    end

    {
      total: global[:total],
      known: global[:total] - rest[:total],
      rest_count: rest[:total],
      global: global,
      rest: rest,
      queues: queues
    }
  end

  def self.outside_virtual_queues(queue_names)
    return all if queue_names.empty?

    where(virtual_queue: [nil, ""]).or(where.not(virtual_queue: queue_names))
  end

  def self.empty_observability_runtime
    {
      total: 0,
      ready: 0,
      scheduled: 0,
      locked: 0,
      next_attempt_at: nil,
      oldest_at: nil
    }
  end
  private_class_method :empty_observability_runtime

  def self.merge_observability_runtime!(target, runtime)
    [:total, :ready, :scheduled, :locked].each do |key|
      target[key] += runtime[key]
    end
    target[:next_attempt_at] = [target[:next_attempt_at], runtime[:next_attempt_at]].compact.min
    target[:oldest_at] = [target[:oldest_at], runtime[:oldest_at]].compact.min
    target
  end
  private_class_method :merge_observability_runtime!

  def self.cast_observability_time(value)
    return if value.blank?
    return value if value.respond_to?(:in_time_zone)

    Time.zone.parse(value.to_s)
  end
  private_class_method :cast_observability_time

  def retry_now
    update!(retry_after: nil)
  end

  def send_bounce
    return unless message.send_bounces?

    BounceMessage.new(server, message).queue
  end

  def allocate_ip_address
    return unless Postal.ip_pools?
    return if message.nil?

    pool = server.ip_pool_for_message(message)
    return if pool.nil?

    self.ip_address = pool.ip_addresses.select_by_priority
  end

  def batchable_messages(limit = 10)
    unless locked?
      raise Postal::Error, "Must lock current message before locking any friends"
    end

    if batch_key.nil?
      []
    else
      time = Time.now
      locker = locked_by
      self.class.ready
                .where(
                  batch_key: batch_key,
                  domain: domain,
                  ip_address_id: ip_address_id,
                  locked_by: nil,
                  locked_at: nil
                )
                .order(:created_at, :id)
                .limit(limit)
                .update_all(locked_by: locker, locked_at: time)
      QueuedMessage.where(
        batch_key: batch_key,
        domain: domain,
        ip_address_id: ip_address_id,
        locked_by: locker,
        locked_at: time
      ).where.not(id: id)
    end
  end

end
