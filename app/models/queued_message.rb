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
    total = scope.count
    locked = scope.where.not(locked_at: nil).count
    ready_scope = scope.where(locked_at: nil).ready_with_delayed_retry
    ready = ready_scope.count
    scheduled_scope = scope.where(locked_at: nil)
                           .where("retry_after IS NOT NULL AND retry_after >= ?", 30.seconds.ago)

    {
      total: total,
      ready: ready,
      scheduled: scheduled_scope.count,
      locked: locked,
      next_attempt_at: scheduled_scope.minimum(:retry_after)
    }
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

    queue_names.index_with do |queue_name|
      {
        total: totals[queue_name].to_i,
        ready: ready[queue_name].to_i,
        scheduled: scheduled[queue_name].to_i,
        locked: locked[queue_name].to_i,
        next_attempt_at: next_attempts[queue_name]
      }
    end
  end

  def self.outside_virtual_queues(queue_names)
    return all if queue_names.empty?

    where(virtual_queue: [nil, ""]).or(where.not(virtual_queue: queue_names))
  end

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
