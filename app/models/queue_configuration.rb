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
#

class QueueConfiguration < ApplicationRecord
  validates :queue_name, presence: true, uniqueness: true
  validates :min_smtp_out, numericality: { greater_than_or_equal_to: 1 }
  validates :max_smtp_out, numericality: { greater_than_or_equal_to: 1 }
  validates :max_rcpt_per_message, numericality: { greater_than_or_equal_to: 1 }

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

  # Check if we can send another message based on rate limits
  def can_send_message?
    return true unless max_msg_rate_per_hour

    # Count messages sent in the last hour for this queue
    # This would need to be implemented with actual message tracking
    true
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
        end
      end
    end
  end
end
