# frozen_string_literal: true

require "rails_helper"

RSpec.describe SMTPSenderWithRollup do
  it "uses mx_connection_attempts instead of max_smtp_out as the endpoint-attempt budget" do
    QueueConfiguration.create!(
      queue_name: "example.queue",
      max_smtp_out: 1,
      mx_connection_attempts: 2
    )
    endpoints = 3.times.map { |index| instance_double(SMTPClient::Endpoint, to_s: "mx-#{index}") }
    servers = endpoints.map do |endpoint|
      instance_double(SMTPClient::Server, hostname: endpoint.to_s, endpoints: [endpoint])
    end
    sender = described_class.new("example.net", servers: servers, queue_name: "example.queue")
    allow(sender).to receive(:connect_to_endpoint).and_return(false)

    expect(sender.start).to be(false)
    expect(sender).to have_received(:connect_to_endpoint).twice
  end

  it "rotates the first MX attempted between queue passes" do
    QueueConfiguration.create!(
      queue_name: "example.queue",
      mx_connection_attempts: 1
    )
    endpoints = 2.times.map { |index| instance_double(SMTPClient::Endpoint, to_s: "mx-#{index}") }
    servers = endpoints.map do |endpoint|
      instance_double(SMTPClient::Server, hostname: endpoint.to_s, endpoints: [endpoint])
    end
    sender = described_class.new(
      "example.net",
      servers: servers,
      queue_name: "example.queue",
      mx_attempt_offset: 1
    )
    allow(sender).to receive(:connect_to_endpoint).and_return(false)

    sender.start

    expect(sender).to have_received(:connect_to_endpoint).with(endpoints.second)
    expect(sender).not_to have_received(:connect_to_endpoint).with(endpoints.first)
  end
end
