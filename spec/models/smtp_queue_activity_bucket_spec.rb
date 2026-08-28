# frozen_string_literal: true

require "rails_helper"

RSpec.describe SMTPQueueActivityBucket do
  describe ".record_result!" do
    it "atomically accumulates one outcome per attempt in a minute bucket" do
      occurred_at = Time.zone.parse("2026-08-28 09:02:30")
      sent = SendResult.new { |result| result.type = "Sent" }
      failed = SendResult.new do |result|
        result.type = "SoftFail"
        result.connect_error = true
        result.rate_limited = true
        result.backoff_matched = true
      end

      described_class.record_result!(queue_name: "example.queue", result: sent, occurred_at: occurred_at)
      described_class.record_result!(queue_name: "example.queue", result: failed, occurred_at: occurred_at + 20.seconds)

      bucket = described_class.find_by!(
        queue_name: "example.queue",
        bucket_started_at: Time.zone.parse("2026-08-28 09:02:00")
      )

      expect(bucket).to have_attributes(
        bucket_started_at: Time.zone.parse("2026-08-28 09:02:00"),
        attempted_count: 2,
        sent_count: 1,
        soft_fail_count: 1,
        hard_fail_count: 0,
        connect_error_count: 1,
        rate_limited_count: 1,
        backoff_matched_count: 1
      )
    end

    it "does not interrupt delivery when the metrics store fails" do
      connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
      allow(described_class).to receive(:connection).and_return(connection)
      allow(connection).to receive(:quote).and_return("NULL")
      allow(connection).to receive(:quote_column_name) { |value| value }
      allow(connection).to receive(:quote_table_name) { |value| value }
      allow(connection).to receive(:execute).and_raise(Mysql2::Error, "metrics unavailable")
      allow(Postal.logger).to receive(:error)

      result = SendResult.new { |value| value.type = "Sent" }

      expect do
        described_class.record_result!(queue_name: "example.queue", result: result)
      end.not_to raise_error
      expect(Postal.logger).to have_received(:error).with(/Could not record SMTP queue activity/, queue: "example.queue")
    end
  end
end
