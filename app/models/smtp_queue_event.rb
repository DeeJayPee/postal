# frozen_string_literal: true

require "digest"

class SMTPQueueEvent < ApplicationRecord

  EVENT_TYPES = %w[
    backoff_entered
    delivery_issue
    backoff_exited
    retry_requested
    diagnostic_succeeded
    diagnostic_failed
  ].freeze
  SOURCES = %w[smtp_rule scheduler manual auto_recovery smtp_probe].freeze
  SEVERITIES = %w[info warning error].freeze
  MAX_TEXT_BYTES = 10.kilobytes
  ISSUE_BUCKET_SIZE = 5.minutes
  EMAIL_ADDRESS_PATTERN = /[A-Z0-9.!#$%&'*+\/=^_`{|}~-]+@([A-Z0-9.-]+)/i
  TRUNCATION_MARKER = "\n[truncated]"

  belongs_to :queue_configuration, optional: true
  belongs_to :backoff_rule, optional: true
  belongs_to :actor, class_name: "User", optional: true

  validates :queue_name, :event_type, :source, :severity, :first_occurred_at, :last_occurred_at, presence: true
  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :source, inclusion: { in: SOURCES }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :occurrence_count, numericality: { greater_than_or_equal_to: 1 }

  scope :recent_first, -> { order(last_occurred_at: :desc, id: :desc) }

  class << self

    def record_transition!(queue_configuration:, event_type:, source:, severity: "info", actor_id: nil,
                           category: nil, rule: nil, result: nil, queued_message: nil, retry_at: nil,
                           details: nil, domain: nil, occurred_at: Time.current)
      context = context_attributes(result: result, queued_message: queued_message)
      context[:domain] = domain if domain.present?
      transition_details = [sanitize_text(details), context.delete(:details)].compact_blank.uniq.join("\n")
      create!(
        context.merge(
          queue_configuration: queue_configuration,
          queue_name: queue_configuration.queue_name,
          event_type: event_type,
          category: category,
          source: source,
          severity: severity,
          first_occurred_at: occurred_at,
          last_occurred_at: occurred_at,
          actor_id: actor_id,
          retry_at: retry_at,
          backoff_rule: rule,
          rule_pattern: sanitize_text(rule&.pattern),
          details: sanitize_text(transition_details)
        )
      )
    end

    def record_delivery_issue!(queue_configuration:, category:, result:, queued_message:, rule: nil,
                               source: "scheduler", occurred_at: Time.current)
      context = context_attributes(result: result, queued_message: queued_message)
      response = context[:smtp_response]
      fingerprint = Digest::SHA256.hexdigest([
        category,
        response,
        context[:domain],
        context[:source_ip],
        context[:remote_endpoint],
        rule&.id,
      ].join("\0"))
      bucket_started_at = Time.at((occurred_at.to_i / ISSUE_BUCKET_SIZE) * ISSUE_BUCKET_SIZE).utc
      lookup = {
        queue_configuration_id: queue_configuration.id,
        event_type: "delivery_issue",
        fingerprint: fingerprint,
        bucket_started_at: bucket_started_at
      }

      event = create_or_find_by!(lookup) do |record|
        record.assign_attributes(
          context.merge(
            queue_name: queue_configuration.queue_name,
            category: category,
            source: source,
            severity: issue_severity(category),
            first_occurred_at: occurred_at,
            last_occurred_at: occurred_at,
            occurrence_count: 1,
            retry_at: retry_at_for(result),
            backoff_rule_id: rule&.id,
            rule_pattern: sanitize_text(rule&.pattern)
          )
        )
      end

      return event if event.previously_new_record?

      event.with_lock do
        event.update_columns(
          occurrence_count: event.occurrence_count + 1,
          last_occurred_at: occurred_at,
          retry_at: retry_at_for(result),
          updated_at: occurred_at
        )
      end
      event
    end

    def sanitize_text(value)
      return if value.blank?

      sanitized = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(EMAIL_ADDRESS_PATTERN, '***@\1')
      return sanitized if sanitized.bytesize <= MAX_TEXT_BYTES

      truncate_utf8_bytes(sanitized, MAX_TEXT_BYTES, marker: TRUNCATION_MARKER)
    end

    def prune_before!(cutoff, batch_size: 1_000)
      deleted = 0
      where("last_occurred_at < ?", cutoff).in_batches(of: batch_size) do |events|
        deleted += events.delete_all
      end
      deleted
    end

    private

    def context_attributes(result:, queued_message:)
      {
        smtp_response: sanitize_text(result&.output),
        details: sanitize_text(result&.details),
        domain: sanitize_dimension(queued_message&.domain.presence || queued_message&.message&.recipient_domain),
        source_ip: sanitize_dimension(result&.source_ip),
        remote_endpoint: sanitize_dimension(result&.remote_endpoint.presence || result&.attempted_endpoints),
        log_id: sanitize_dimension(result&.log_id),
        queued_message_id: queued_message&.id,
        message_id: queued_message&.message_id,
        server_id: queued_message&.server_id
      }
    end

    def retry_at_for(result)
      seconds = result&.queue_retry_after || (result&.retry if result&.retry.is_a?(Numeric))
      Time.current + seconds.to_i.seconds if seconds
    end

    def issue_severity(category)
      category.to_s == "hard_fail" ? "error" : "warning"
    end

    def sanitize_dimension(value)
      sanitized = sanitize_text(value)
      return if sanitized.blank?

      truncate_utf8_bytes(sanitized, 255)
    end

    def truncate_utf8_bytes(value, max_bytes, marker: "")
      return value if value.bytesize <= max_bytes

      content_size = max_bytes - marker.bytesize
      content = value.byteslice(0, content_size).scrub("")
      "#{content}#{marker}"
    end

  end

end
