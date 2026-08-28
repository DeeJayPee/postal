# frozen_string_literal: true

require "rails_helper"

RSpec.describe PruneSMTPQueueObservabilityScheduledTask do
  let(:logger) { TestLogger.new }

  subject(:task) { described_class.new(logger: logger) }

  it "deletes expired events and activity buckets in batches" do
    allow(Postal::Config.postal).to receive(:queue_observability_retention_days).and_return(30)
    queue = QueueConfiguration.create!(queue_name: "example.queue", mode: "normal")
    old_time = 31.days.ago
    recent_time = 29.days.ago

    old_event = SMTPQueueEvent.record_transition!(
      queue_configuration: queue,
      event_type: "retry_requested",
      source: "manual",
      occurred_at: old_time
    )
    recent_event = SMTPQueueEvent.record_transition!(
      queue_configuration: queue,
      event_type: "retry_requested",
      source: "manual",
      occurred_at: recent_time
    )
    old_bucket = SMTPQueueActivityBucket.create!(queue_name: queue.queue_name, bucket_started_at: old_time)
    recent_bucket = SMTPQueueActivityBucket.create!(queue_name: queue.queue_name, bucket_started_at: recent_time)

    task.call

    expect(SMTPQueueEvent.where(id: old_event.id)).not_to exist
    expect(SMTPQueueEvent.where(id: recent_event.id)).to exist
    expect(SMTPQueueActivityBucket.where(id: old_bucket.id)).not_to exist
    expect(SMTPQueueActivityBucket.where(id: recent_bucket.id)).to exist
    expect(logger).to have_logged(/Pruned SMTP queue observability history/)
  end
end
