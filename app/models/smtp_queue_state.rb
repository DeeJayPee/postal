# frozen_string_literal: true

class SMTPQueueState < ApplicationRecord
  include HasPrometheusMetrics

  RateDecision = Struct.new(:allowed, :retry_after, keyword_init: true) do
    def allowed?
      allowed
    end
  end

  has_many :smtp_queue_leases, dependent: :delete_all

  validates :queue_key, presence: true, uniqueness: true
  validates :consecutive_failures, numericality: { greater_than_or_equal_to: 0 }
  validates :rate_attempts, numericality: { greater_than_or_equal_to: 0 }

  def self.queue_key_for(queued_message)
    if queued_message.virtual_queue.present?
      "virtual:#{queued_message.virtual_queue}"
    elsif queued_message.batch_key.to_s.start_with?("outgoing-")
      "domain:#{queued_message.domain}"
    else
      "batch:#{queued_message.batch_key.presence || queued_message.id}"
    end
  end

  def self.for_message!(queued_message)
    outgoing_domain_queue = queued_message.batch_key.to_s.start_with?("outgoing-")
    batch_state_key = if queued_message.virtual_queue.blank? && !outgoing_domain_queue
                        queued_message.batch_key.presence || "__message__:#{queued_message.id}"
                      end
    attributes = {
      queue_key: queue_key_for(queued_message),
      virtual_queue: queued_message.virtual_queue.presence,
      domain: (queued_message.domain if queued_message.virtual_queue.blank? && outgoing_domain_queue),
      batch_key: batch_state_key
    }

    create_or_find_by!(queue_key: attributes[:queue_key]) do |state|
      state.assign_attributes(attributes)
    end
  end

  def self.for_virtual_queue!(queue_name)
    create_or_find_by!(queue_key: "virtual:#{queue_name}") do |state|
      state.virtual_queue = queue_name
    end
  end

  def queue_configuration
    return if virtual_queue.blank?

    QueueConfiguration.find_for_queue(virtual_queue)
  end

  def eligible?(now = Time.current)
    next_attempt_at.nil? || next_attempt_at <= now
  end

  def connection_limit
    config = queue_configuration
    return 100 if queue_key.start_with?("batch:")
    return 1 unless config
    return 1 if consecutive_failures.positive?

    config.effective_max_smtp_out
  end

  def acquire_lease!(queued_message:, locker:, now: Time.current)
    with_lock do
      return if !eligible?(now) || smtp_queue_leases.where("expires_at > ?", now).count >= connection_limit

      lease = smtp_queue_leases.create!(
        queued_message_id: queued_message.id,
        locker: locker,
        expires_at: now + SMTPQueueLease::TTL
      )
      update_columns(last_dispatched_at: now, updated_at: now)
      increment_prometheus_counter :postal_smtp_queue_dispatches_total,
                                   labels: { queue: metric_queue_name }
      lease
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def record_result!(result)
    if result.type == "Sent"
      record_success!
      :success
    elsif result.queue_retry_after
      defer_for!(result.queue_retry_after, result.output.presence || result.details)
      :deferred
    elsif result.connect_error || queue_configuration&.backoff?
      record_failure!(result.output.presence || result.details)
      :deferred
    else
      :none
    end
  end

  def record_success!
    with_lock do
      update_columns(
        next_attempt_at: nil,
        consecutive_failures: 0,
        last_error: nil,
        updated_at: Time.current
      )
      increment_prometheus_counter :postal_smtp_queue_results_total,
                                   labels: { queue: metric_queue_name, result: "sent" }
    end
  end

  def record_failure!(error)
    with_lock do
      config = queue_configuration
      retry_seconds = if config&.backoff?
                        config.backoff_retry_after_seconds
                      else
                        config&.retry_after_seconds || 10.minutes.to_i
                      end
      now = Time.current
      update_columns(
        next_attempt_at: now + retry_seconds,
        consecutive_failures: consecutive_failures + 1,
        last_error: error.to_s.truncate(10_000),
        updated_at: now
      )
      increment_prometheus_counter :postal_smtp_queue_results_total,
                                   labels: { queue: metric_queue_name, result: "connect_error" }
    end
  end

  def defer_for!(seconds, error = nil)
    with_lock do
      now = Time.current
      update_columns(
        next_attempt_at: now + seconds.to_i,
        last_error: error.to_s.truncate(10_000),
        updated_at: now
      )
      increment_prometheus_counter :postal_smtp_queue_deferrals_total,
                                   labels: { queue: metric_queue_name, reason: "rate_limit" }
    end
  end

  def retry_now!
    update_columns(
      next_attempt_at: nil,
      consecutive_failures: 0,
      last_error: nil,
      updated_at: Time.current
    )
  end

  def reserve_message_attempt!(queue_config)
    rate = queue_config.parsed_max_msg_rate
    return RateDecision.new(allowed: true) unless rate

    with_lock do
      now = Time.current
      window_expired = rate_window_started_at.nil? || rate_window_started_at <= now - rate[:period].seconds
      if window_expired
        self.rate_window_started_at = now
        self.rate_attempts = 0
      end

      if rate_attempts >= rate[:count]
        retry_in = [(rate_window_started_at + rate[:period].seconds - now).ceil, 1].max
        save! if changed?
        return RateDecision.new(allowed: false, retry_after: retry_in)
      end

      self.rate_attempts += 1
      save!
      RateDecision.new(allowed: true)
    end
  end

  def message_attempt_available?(queue_config)
    rate = queue_config.parsed_max_msg_rate
    return true unless rate
    return true if rate_window_started_at.nil? || rate_window_started_at <= Time.current - rate[:period].seconds

    rate_attempts < rate[:count]
  end

  def active_lease_count
    if smtp_queue_leases.loaded?
      return smtp_queue_leases.count { |lease| lease.expires_at > Time.current }
    end

    smtp_queue_leases.where("expires_at > ?", Time.current).count
  end

  private

  def metric_queue_name
    virtual_queue.presence || "rest"
  end
end
