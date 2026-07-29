# frozen_string_literal: true

require "rails_helper"

RSpec.describe SMTPQueueState do
  let(:queue) { QueueConfiguration.create!(queue_name: "example.queue", max_msg_rate: "2/s") }
  let(:state) { described_class.for_virtual_queue!(queue.queue_name) }

  it "counts attempted recipients atomically in the configured window" do
    expect(state.reserve_message_attempt!(queue)).to be_allowed
    expect(state.reserve_message_attempt!(queue)).to be_allowed

    blocked = state.reserve_message_attempt!(queue)
    expect(blocked).not_to be_allowed
    expect(blocked.retry_after).to be >= 1
  end

  it "defers the whole queue after a connection failure and resets it on success" do
    result = SendResult.new
    result.type = "SoftFail"
    result.connect_error = true
    result.output = "connection timed out"

    state.record_result!(result)

    expect(state.reload.next_attempt_at).to be_within(1.second).of(10.minutes.from_now)
    expect(state.consecutive_failures).to eq(1)
    expect(state.last_error).to eq("connection timed out")

    result.type = "Sent"
    result.connect_error = false
    state.record_result!(result)

    expect(state.reload.next_attempt_at).to be_nil
    expect(state.consecutive_failures).to eq(0)
  end
end
