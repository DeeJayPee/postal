# frozen_string_literal: true

require "rails_helper"

RSpec.describe SMTPQueueEvent do
  let(:queue) { QueueConfiguration.create!(queue_name: "example.queue", mode: "normal") }
  let(:queued_message) do
    instance_double(
      QueuedMessage,
      id: 123,
      message_id: 456,
      server_id: 7,
      domain: "example.com",
      message: nil
    )
  end
  let(:result) do
    SendResult.new do |value|
      value.type = "SoftFail"
      value.output = "451 mailbox john@example.com is temporarily unavailable"
      value.details = "Delivery for jane@example.com was deferred"
      value.source_ip = "192.0.2.10"
      value.remote_endpoint = "mx.example.com (192.0.2.20)"
      value.log_id = "LOG123"
      value.retry = 120
    end
  end

  describe ".record_transition!" do
    it "persists structured context while masking email local parts" do
      event = described_class.record_transition!(
        queue_configuration: queue,
        event_type: "backoff_entered",
        category: "smtp_rule",
        source: "smtp_rule",
        severity: "warning",
        result: result,
        queued_message: queued_message,
        details: "Triggered for operator@example.net"
      )

      expect(event).to have_attributes(
        queue_name: "example.queue",
        domain: "example.com",
        source_ip: "192.0.2.10",
        remote_endpoint: "mx.example.com (192.0.2.20)",
        log_id: "LOG123",
        queued_message_id: 123,
        message_id: 456,
        server_id: 7
      )
      expect(event.smtp_response).to eq("451 mailbox ***@example.com is temporarily unavailable")
      expect(event.details).to include("Triggered for ***@example.net")
      expect(event.details).to include("Delivery for ***@example.com was deferred")
    end
  end

  describe ".record_delivery_issue!" do
    it "aggregates identical issues in the same five-minute bucket" do
      occurred_at = Time.zone.parse("2026-08-28 09:02:00")

      2.times do
        described_class.record_delivery_issue!(
          queue_configuration: queue,
          category: "soft_fail",
          result: result,
          queued_message: queued_message,
          occurred_at: occurred_at
        )
      end

      events = described_class.where(queue_configuration: queue, event_type: "delivery_issue")

      expect(events.count).to eq(1)
      expect(events.first).to have_attributes(
        occurrence_count: 2,
        bucket_started_at: Time.zone.parse("2026-08-28 09:00:00")
      )
    end

    it "starts a new aggregate in the next five-minute bucket" do
      ["09:04:59", "09:05:00"].each do |clock|
        described_class.record_delivery_issue!(
          queue_configuration: queue,
          category: "soft_fail",
          result: result,
          queued_message: queued_message,
          occurred_at: Time.zone.parse("2026-08-28 #{clock}")
        )
      end

      expect(described_class.where(queue_configuration: queue, event_type: "delivery_issue").count).to eq(2)
    end
  end

  describe ".sanitize_text" do
    it "scrubs invalid characters and limits persisted text to ten kilobytes" do
      value = ("john@example.com\xFF".b * 1_000)
      sanitized = described_class.sanitize_text(value)

      expect(sanitized).not_to include("john@example.com")
      expect(sanitized).to end_with("[truncated]")
      expect(sanitized.bytesize).to be <= described_class::MAX_TEXT_BYTES
      expect(sanitized.encoding).to eq(Encoding::UTF_8)
      expect(sanitized).to be_valid_encoding
    end
  end
end
