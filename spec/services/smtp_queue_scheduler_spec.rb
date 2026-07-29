# frozen_string_literal: true

require "rails_helper"

RSpec.describe SMTPQueueScheduler do
  def scheduler(locker)
    described_class.new(ip_address_ids: [], locker: locker)
  end

  it "lets another queue progress while a limited queue owns its only slot" do
    QueueConfiguration.create!(queue_name: "a-broken.queue", max_smtp_out: 1)
    QueueConfiguration.create!(queue_name: "b-gmail.queue", max_smtp_out: 4)
    broken = create(:queued_message, virtual_queue: "a-broken.queue", domain: "customer.example")
    gmail = create(:queued_message, virtual_queue: "b-gmail.queue", domain: "gmail.com")

    first = scheduler("worker-1").claim
    second = scheduler("worker-2").claim

    expect(first.message).to eq(broken)
    expect(second.message).to eq(gmail)
  ensure
    first&.lease&.release!
    second&.lease&.release!
  end

  it "keeps seven of eight worker slots available when a failing queue is capped at one" do
    QueueConfiguration.create!(queue_name: "a-broken.queue", max_smtp_out: 1)
    QueueConfiguration.create!(queue_name: "b-gmail.queue", max_smtp_out: 8)
    8.times { create(:queued_message, virtual_queue: "a-broken.queue", domain: "customer.example") }
    7.times { create(:queued_message, virtual_queue: "b-gmail.queue", domain: "gmail.com") }

    claims = 8.times.map { |index| scheduler("worker-#{index}").claim }
    queue_names = claims.map { |claim| claim.message.virtual_queue }

    expect(queue_names.count("a-broken.queue")).to eq(1)
    expect(queue_names.count("b-gmail.queue")).to eq(7)
  ensure
    claims&.each { |claim| claim&.lease&.release! }
  end

  it "enforces max_smtp_out across independent scheduler instances" do
    QueueConfiguration.create!(queue_name: "example.queue", max_smtp_out: 2)
    3.times { create(:queued_message, virtual_queue: "example.queue") }

    first = scheduler("worker-1").claim
    second = scheduler("worker-2").claim
    third = scheduler("worker-3").claim

    expect(first).to be_present
    expect(second).to be_present
    expect(third).to be_nil
    expect(SMTPQueueState.for_virtual_queue!("example.queue").active_lease_count).to eq(2)
  ensure
    first&.lease&.release!
    second&.lease&.release!
  end

  it "recovers the message lock held by an expired lease" do
    QueueConfiguration.create!(queue_name: "example.queue", max_smtp_out: 1)
    stale_message = create(
      :queued_message,
      :locked,
      locked_by: "dead-worker",
      virtual_queue: "example.queue"
    )
    state = SMTPQueueState.for_virtual_queue!("example.queue")
    state.smtp_queue_leases.create!(
      queued_message_id: stale_message.id,
      locker: "dead-worker",
      expires_at: 1.minute.ago
    )

    claim = scheduler("worker-2").claim

    expect(claim.message).to eq(stale_message)
    expect(stale_message.reload.locked_by).to eq("worker-2")
  ensure
    claim&.lease&.release!
  end

  it "allows only one half-open claim after a queue retry delay expires" do
    QueueConfiguration.create!(queue_name: "example.queue", max_smtp_out: 4)
    2.times { create(:queued_message, virtual_queue: "example.queue") }
    state = SMTPQueueState.for_virtual_queue!("example.queue")
    state.update!(next_attempt_at: 1.second.ago, consecutive_failures: 1)

    probe = scheduler("worker-1").claim
    concurrent = scheduler("worker-2").claim

    expect(probe).to be_present
    expect(concurrent).to be_nil
  ensure
    probe&.lease&.release!
  end
end
