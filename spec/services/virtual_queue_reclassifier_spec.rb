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

end
