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
  validates :queue_name, presence: true, uniqueness: true
  validates :min_smtp_out, numericality: { greater_than_or_equal_to: 1 }
  validates :max_smtp_out, numericality: { greater_than_or_equal_to: 1 }
  validates :max_rcpt_per_message, numericality: { greater_than_or_equal_to: 1 }
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

  # Get the backoff reroute IP address if configured
  def backoff_ip_address
    return nil if backoff_reroute_to.blank?

    # Parse IP address (supports both IPv4 and IPv6)
    begin
      require 'ipaddr'
      IPAddr.new(backoff_reroute_to)
    rescue IPAddr::InvalidAddressError, ArgumentError
      nil
    end
  end

  private

  def validate_max_msg_rate_format
    return if max_msg_rate.blank?

    unless max_msg_rate =~ /^\d+\/(d|h|m|s)$/
      errors.add(:max_msg_rate, 'must be in format: number/unit (e.g., 10000/d, 2000/h, 100/m, 10/s)')
    end
  end

  def validate_backoff_reroute_to_format
    return if backoff_reroute_to.blank?

    begin
      require 'ipaddr'
      IPAddr.new(backoff_reroute_to)
    rescue IPAddr::InvalidAddressError, ArgumentError
      errors.add(:backoff_reroute_to, 'must be a valid IP address (IPv4 or IPv6)')
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
        end
      end
    end
  end
end
