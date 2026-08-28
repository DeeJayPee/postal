# frozen_string_literal: true

class PruneSMTPQueueObservabilityScheduledTask < ApplicationScheduledTask

  def call
    cutoff = Postal::Config.postal.queue_observability_retention_days.days.ago
    event_count = SMTPQueueEvent.prune_before!(cutoff)
    bucket_count = SMTPQueueActivityBucket.prune_before!(cutoff)
    logger.info "Pruned SMTP queue observability history", events: event_count, activity_buckets: bucket_count
  end

  def self.next_run_after
    three_am
  end

end
