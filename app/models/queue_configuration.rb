# frozen_string_literal: true

# == Schema Information
#
# Table name: queue_configurations
#
#  id                     :integer          not null, primary key
#  queue_name             :string(255)      not null
#  min_smtp_out           :integer          default(1)
#  max_smtp_out           :integer          default(1)
#  max_rcpt_per_message   :integer          default(100)
#  max_msg_rate_per_hour  :integer
#  max_conn_rate_per_hour :integer
#  enabled                :boolean          default(TRUE)
#  description            :text(65535)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  max_msg_rate           :string(255)
#  backoff_reroute_to     :string(255)
#

class QueueConfiguration < ApplicationRecord
  MODES = %w[normal backoff].freeze

  before_validation :normalize_queue_name

  validates :queue_name, presence: true, uniqueness: true
  validates :min_smtp_out, numericality: { greater_than_or_equal_to: 1 }
  validates :max_smtp_out, numericality: { greater_than_or_equal_to: 1 }
  validates :max_rcpt_per_message, numericality: { greater_than_or_equal_to: 1 }
  validates :mode, inclusion: { in: MODES }, allow_nil: true
  validates :backoff_base_delay_seconds, numericality: { greater_than_or_equal_to: 1 }, allow_nil: true
  validates :backoff_auto_success_threshold, numericality: { greater_than_or_equal_to: 1 }, allow_nil: true
  validates :backoff_auto_success_window_seconds, numericality: { greater_than_or_equal_to: 1 }, allow_nil: true
  validates :backoff_success_count, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :validate_max_msg_rate_format
  validate :validate_backoff_reroute_to_format

  scope :enabled, -> { where(enabled: true) }

  # Find configuration for a queue
  def self.find_for_queue(queue_name)
    enabled.find_by(queue_name: queue_name)
  end

  # Get the effective max concurrent connections for this queue
  def effective_max_smtp_out
    max_smtp_out || 1
  end

  # Get the effective min concurrent connections for this queue
  def effective_min_smtp_out
    [min_smtp_out || 1, effective_max_smtp_out].min
  end

  def normal?
    mode.to_s == "normal"
  end

  def backoff?
    mode.to_s == "backoff"
  end

  def enter_backoff!
    transaction do
      update!(
        mode: "backoff",
        backoff_started_at: Time.current,
        backoff_last_success_at: nil,
        backoff_success_count: 0
      )

      if backoff_reroute_to.present?
        QueuedMessage.where(virtual_queue: queue_name, locked_at: nil)
                     .where("retry_after IS NOT NULL AND retry_after >= ?", 30.seconds.ago)
                     .update_all(retry_after: nil)
      end
    end
  end

  def exit_backoff!
    update!(
      mode: "normal",
      backoff_started_at: nil,
      backoff_last_success_at: nil,
      backoff_success_count: 0
    )
  end

  # Track successful sends while in backoff mode and auto-return when configured.
  #
  # @return [Boolean] true if queue has been switched back to normal
  def register_backoff_success!
    return false unless backoff?

    now = Time.current
    window = backoff_auto_success_window_seconds.to_i
    threshold = backoff_auto_success_threshold.to_i
    reset_count = window.positive? && backoff_last_success_at.present? && backoff_last_success_at < now - window.seconds
    next_count = reset_count ? 1 : backoff_success_count.to_i + 1

    attrs = {
      backoff_success_count: next_count,
      backoff_last_success_at: now
    }

    if threshold.positive? && next_count >= threshold
      attrs.merge!(
        mode: "normal",
        backoff_started_at: nil,
        backoff_last_success_at: nil,
        backoff_success_count: 0
      )
      update!(attrs)
      return true
    end

    update!(attrs)
    false
  end

  def register_backoff_failure!
    return unless backoff?

    update_columns(backoff_last_success_at: nil, backoff_success_count: 0)
  end

  def effective_backoff_base_delay
    [backoff_base_delay_seconds.to_i, 2.hours.to_i].max
  end

  def rate_limit_retry_seconds
    return 60 unless max_msg_rate.present?

    rate = parsed_max_msg_rate
    return 60 unless rate

    [((rate[:period].to_f / rate[:count].to_f).ceil), 60].max
  end

  # Parse max_msg_rate string (e.g., "2000/h", "100/m", "10000/d") into messages per second
  # Returns nil if not set or invalid format
  def parsed_max_msg_rate
    return nil if max_msg_rate.blank?

    if max_msg_rate =~ /^(\d+)\/(d|h|m|s)$/
      count = ::Regexp.last_match(1).to_i
      unit = ::Regexp.last_match(2)

      case unit
      when 'd' # per day
        { count: count, period: 86400, per_second: count / 86400.0 }
      when 'h' # per hour
        { count: count, period: 3600, per_second: count / 3600.0 }
      when 'm' # per minute
        { count: count, period: 60, per_second: count / 60.0 }
      when 's' # per second
        { count: count, period: 1, per_second: count.to_f }
      end
    end
  end

  # Check if we can send another message based on rate limits
  def can_send_message?
    return true unless max_msg_rate.present?

    rate = parsed_max_msg_rate
    return true unless rate

    # Count messages sent in the rate period for this queue
    cutoff_time = Time.current - rate[:period].seconds
    sent_count = QueuedMessage.where(virtual_queue: queue_name)
                               .where('created_at >= ?', cutoff_time)
                               .count

    sent_count < rate[:count]
  end

  # Get the backoff reroute relay server if configured
  # Returns the hostname or IP address to use as an alternative relay
  def backoff_relay_server
    return nil if backoff_reroute_to.blank? || !backoff?

    backoff_reroute_to
  end

  private

  def normalize_queue_name
    self.queue_name = queue_name.to_s.strip
  end

  def validate_max_msg_rate_format
    return if max_msg_rate.blank?

    unless max_msg_rate =~ /^\d+\/(d|h|m|s)$/
      errors.add(:max_msg_rate, 'must be in format: number/unit (e.g., 10000/d, 2000/h, 100/m, 10/s)')
    end
  end

  def validate_backoff_reroute_to_format
    return if backoff_reroute_to.blank?

    # Validate hostname or IP address format
    # Allow: hostnames (relay.example.com), IPv4 (192.168.1.1), IPv6 ([2001:db8::1])
    hostname_pattern = /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/
    ipv4_pattern = /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
    ipv6_pattern = /^\[?(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\]?$|^\[?::(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4}\]?$|^\[?[0-9a-fA-F]{1,4}::(?:[0-9a-fA-F]{1,4}:){0,5}[0-9a-fA-F]{1,4}\]?$/

    unless backoff_reroute_to =~ hostname_pattern || backoff_reroute_to =~ ipv4_pattern || backoff_reroute_to =~ ipv6_pattern
      errors.add(:backoff_reroute_to, 'must be a valid hostname or IP address')
    end
  end

  # Import from PowerMTA-style configuration
  def self.import_from_config(config_text)
    current_queue = nil

    config_text.each_line do |line|
      next if line.strip.start_with?("#") || line.strip.empty?

      if line =~ /^\s*<domain\s+(\S+)>/
        queue_name = ::Regexp.last_match(1)
        current_queue = find_or_initialize_by(queue_name: queue_name)
      elsif line =~ /^\s*<\/domain>/
        current_queue&.save
        current_queue = nil
      elsif current_queue
        if line =~ /^\s*min-smtp-out\s+(\d+)/
          current_queue.min_smtp_out = ::Regexp.last_match(1).to_i
        elsif line =~ /^\s*max-smtp-out\s+(\d+)/
          current_queue.max_smtp_out = ::Regexp.last_match(1).to_i
        elsif line =~ /^\s*max-rcpt-per-message\s+(\d+)/
          current_queue.max_rcpt_per_message = ::Regexp.last_match(1).to_i
        elsif line =~ /^\s*max-msg-rate\s+(\d+\/[dhms])/
          current_queue.max_msg_rate = ::Regexp.last_match(1)
        elsif line =~ /^\s*backoff-reroute-to\s+(\S+)/
          current_queue.backoff_reroute_to = ::Regexp.last_match(1)
        elsif line =~ /^\s*backoff-base-delay\s+(\d+)([dhms])/
          count = ::Regexp.last_match(1).to_i
          unit = ::Regexp.last_match(2)
          current_queue.backoff_base_delay_seconds = duration_to_seconds(count, unit)
        elsif line =~ /^\s*mode\s+(normal|backoff)/
          current_queue.mode = ::Regexp.last_match(1)
        elsif line =~ /^\s*backoff-auto-success-threshold\s+(\d+)/
          current_queue.backoff_auto_success_threshold = ::Regexp.last_match(1).to_i
        elsif line =~ /^\s*backoff-auto-success-window\s+(\d+)([dhms])/
          count = ::Regexp.last_match(1).to_i
          unit = ::Regexp.last_match(2)
          current_queue.backoff_auto_success_window_seconds = duration_to_seconds(count, unit)
        end
      end
    end
  end

  def self.duration_to_seconds(count, unit)
    case unit
    when "d"
      count.days.to_i
    when "h"
      count.hours.to_i
    when "m"
      count.minutes.to_i
    when "s"
      count.seconds.to_i
    else
      count
    end
  end

  public_class_method :duration_to_seconds
end
