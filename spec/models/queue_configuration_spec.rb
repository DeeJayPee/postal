# frozen_string_literal: true

require "rails_helper"

RSpec.describe QueueConfiguration do
  let(:queue) do
    described_class.create!(
      queue_name: "test.queue",
      min_smtp_out: 1,
      max_smtp_out: 1,
      max_rcpt_per_message: 100,
      mode: "normal"
    )
  end

  describe "#backoff_relay_server" do
    it "only returns relay when queue is in backoff mode" do
      queue.update!(backoff_reroute_to: "relay.example.test", mode: "normal")
      expect(queue.backoff_relay_server).to be_nil

      queue.update!(mode: "backoff")
      expect(queue.backoff_relay_server).to eq("relay.example.test")
    end
  end

  describe "#enter_backoff!" do
    it "makes scheduled unlocked messages immediately eligible when a relay is configured" do
      queue.update!(backoff_reroute_to: "relay.example.test")
      scheduled = create(:queued_message, virtual_queue: queue.queue_name, retry_after: 1.hour.from_now)
      locked = create(:queued_message, :locked, virtual_queue: queue.queue_name, retry_after: 1.hour.from_now)

      queue.enter_backoff!

      expect(scheduled.reload.retry_after).to be_nil
      expect(locked.reload.retry_after).to be_present
    end
  end

  describe "#register_backoff_success!" do
    it "auto-exits backoff when threshold is reached in the window" do
      queue.update!(
        mode: "backoff",
        backoff_auto_success_threshold: 2,
        backoff_auto_success_window_seconds: 3600,
        backoff_success_count: 0,
        backoff_last_success_at: nil
      )

      expect(queue.register_backoff_success!).to eq(false)
      expect(queue.reload.mode).to eq("backoff")

      expect(queue.register_backoff_success!).to eq(true)
      expect(queue.reload.mode).to eq("normal")
    end
  end

  describe "#effective_backoff_base_delay" do
    it "enforces a minimum backoff delay of 2 hours" do
      queue.update!(backoff_base_delay_seconds: 60)
      expect(queue.effective_backoff_base_delay).to eq(2.hours.to_i)

      queue.update!(backoff_base_delay_seconds: 3.hours.to_i)
      expect(queue.effective_backoff_base_delay).to eq(3.hours.to_i)
    end
  end

  describe "#rate_limit_retry_seconds" do
    it "returns a computed retry spacing for max-msg-rate" do
      queue.update!(max_msg_rate: "120/h")
      expect(queue.rate_limit_retry_seconds).to eq(60)

      queue.update!(max_msg_rate: "30/h")
      expect(queue.rate_limit_retry_seconds).to eq(120)
    end
  end

  describe "scheduler settings" do
    it "uses separate normal and backoff connection limits" do
      queue.update!(max_smtp_out: 5, backoff_max_smtp_out: 1)
      expect(queue.effective_max_smtp_out).to eq(5)

      queue.enter_backoff!
      expect(queue.effective_max_smtp_out).to eq(1)
    end

    it "parses queue retry intervals" do
      queue.update!(retry_after: "15m", backoff_retry_after: "2h")

      expect(queue.retry_after_seconds).to eq(15.minutes.to_i)
      expect(queue.backoff_retry_after_seconds).to eq(2.hours.to_i)
    end
  end
end
