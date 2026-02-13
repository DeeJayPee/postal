# frozen_string_literal: true

class BackoffRule < ApplicationRecord
  ACTION_MODE_BACKOFF = "mode=backoff"
  ACTION_BOUNCE_RCPT = "bounce-rcpt"
  ACTIONS = [ACTION_MODE_BACKOFF, ACTION_BOUNCE_RCPT].freeze

  validates :pattern, presence: true
  validates :action, inclusion: { in: ACTIONS }

  scope :enabled, -> { where(enabled: true) }

  def self.match_for_response(response_text)
    return nil if response_text.blank?

    enabled.find_each do |rule|
      next unless rule.matches?(response_text)

      return rule
    end

    nil
  end

  def matches?(response_text)
    return false if response_text.blank? || pattern.blank?

    Regexp.new(pattern, Regexp::IGNORECASE).match?(response_text)
  rescue RegexpError
    false
  end

  def self.import_from_config(config_text)
    current_pattern_list = nil

    config_text.each_line do |line|
      stripped = line.strip
      next if stripped.start_with?("#") || stripped.empty?

      if stripped =~ /^<smtp-pattern-list\s+(\S+)>/
        current_pattern_list = Regexp.last_match(1)
        next
      end

      if stripped =~ /^<\/smtp-pattern-list>/
        current_pattern_list = nil
        next
      end

      next unless current_pattern_list

      if stripped =~ %r{^reply\s+/((?:\\/|[^/])*)/\s+mode=backoff$}
        add_or_update_rule!(Regexp.last_match(1), ACTION_MODE_BACKOFF, current_pattern_list)
      elsif stripped =~ %r{^reply\s+/((?:\\/|[^/])*)/\s+bounce-rcpt$}
        add_or_update_rule!(Regexp.last_match(1), ACTION_BOUNCE_RCPT, current_pattern_list)
      end
    end
  end

  def self.add_or_update_rule!(pattern, action, pattern_list)
    rule = find_or_initialize_by(pattern: pattern, action: action)
    rule.enabled = true
    rule.description = pattern_list
    rule.save!
    rule
  end
end
