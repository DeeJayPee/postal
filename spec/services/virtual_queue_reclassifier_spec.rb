# frozen_string_literal: true

require "rails_helper"

RSpec.describe VirtualQueueReclassifier do

  let(:server) { create(:server) }

  it "assigns an existing outgoing message using the current MX mappings" do
    message = MessageFactory.outgoing(server)
    queued_message = create(
      :queued_message,
      message: message,
      domain: "customer.example",
      virtual_queue: nil,
      batch_key: "outgoing-customer.example"
    )
    allow(SMTPRollupService).to receive(:resolve_virtual_queue).with("customer.example").and_return("ovh.queue")

    result = described_class.new(enabled_queue_names: ["ovh.queue"]).call

    expect(result.updated).to eq(1)
    expect(queued_message.reload).to have_attributes(
      virtual_queue: "ovh.queue",
      batch_key: "outgoing-ovh.queue"
    )
  end

  it "does not assign incoming messages to outbound virtual queues" do
    message = MessageFactory.incoming(server)
    queued_message = create(:queued_message, message: message, domain: "customer.example", virtual_queue: nil)
    allow(SMTPRollupService).to receive(:resolve_virtual_queue)

    result = described_class.new(enabled_queue_names: ["ovh.queue"]).call

    expect(result.updated).to eq(0)
    expect(queued_message.reload.virtual_queue).to be_nil
    expect(SMTPRollupService).not_to have_received(:resolve_virtual_queue)
  end

  it "supports a dry run over already assigned pending messages" do
    message = MessageFactory.outgoing(server)
    queued_message = create(
      :queued_message,
      message: message,
      domain: "customer.example",
      virtual_queue: "old.queue",
      batch_key: "outgoing-old.queue"
    )
    allow(SMTPRollupService).to receive(:resolve_virtual_queue).with("customer.example").and_return("new.queue")

    result = described_class.new(
      enabled_queue_names: ["new.queue"],
      dry_run: true,
      only_unassigned: false
    ).call

    expect(result.updated).to eq(1)
    expect(queued_message.reload).to have_attributes(
      virtual_queue: "old.queue",
      batch_key: "outgoing-old.queue"
    )
  end

  it "can restrict reclassification to the resolved target queue" do
    first_message = MessageFactory.outgoing(server)
    second_message = MessageFactory.outgoing(server)
    first = create(:queued_message, message: first_message, virtual_queue: nil)
    second = create(:queued_message, message: second_message, virtual_queue: nil)
    first.update_columns(domain: "first.example")
    second.update_columns(domain: "second.example")
    allow(SMTPRollupService).to receive(:resolve_virtual_queue).with("first.example").and_return("first.queue")
    allow(SMTPRollupService).to receive(:resolve_virtual_queue).with("second.example").and_return("second.queue")

    result = described_class.new(
      enabled_queue_names: ["first.queue", "second.queue"],
      target_queue_name: "first.queue",
      only_unassigned: false
    ).call

    expect(result.updated).to eq(1)
    expect(first.reload.virtual_queue).to eq("first.queue")
    expect(second.reload.virtual_queue).to be_nil
  end

end
