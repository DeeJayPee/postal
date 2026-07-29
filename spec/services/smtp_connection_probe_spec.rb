# frozen_string_literal: true

require "rails_helper"

RSpec.describe SMTPConnectionProbe do

  describe "#call" do
    let(:resolver) { instance_double(DNSResolver) }
    let(:server) { instance_double(SMTPClient::Server, hostname: "mx.example.net") }
    let(:endpoint) { instance_double(SMTPClient::Endpoint, server: server, to_s: "192.0.2.1:25 (mx.example.net)") }
    let(:smtp) { instance_double(Net::SMTP) }
    let(:response) { instance_double(Net::SMTP::Response, string: "250 2.1.5 OK") }

    before do
      allow(SMTPRollupService).to receive(:resolve_virtual_queue).with("example.net").and_return("example.queue")
      allow(QueueConfiguration).to receive(:find_for_queue).with("example.queue").and_return(nil)
      allow(SMTPSender).to receive(:smtp_relays).and_return(nil)
      allow(DNSResolver).to receive(:local).and_return(resolver)
      allow(resolver).to receive(:mx).with("example.net", raise_timeout_errors: true).and_return([[10, "mx.example.net"]])
      allow(SMTPClient::Server).to receive(:new).with("mx.example.net").and_return(server)
      allow(server).to receive(:endpoints).and_return([endpoint])
      allow(endpoint).to receive(:start_smtp_session) do |debug_output:|
        debug_output.puts("S: 220 mx.example.net ESMTP")
        smtp
      end
      allow(endpoint).to receive(:reset_smtp_session)
      allow(endpoint).to receive(:finish_smtp_session)
      allow(smtp).to receive(:mailfrom).with("")
      allow(smtp).to receive(:rcptto).with("user@example.net").and_return(response)
      allow(smtp).to receive(:send_message)
    end

    it "captures a successful SMTP envelope probe without sending DATA" do
      result = described_class.new(
        recipient: "user@example.net",
        queue_name: "example.queue"
      ).call

      expect(result.connected).to be(true)
      expect(result.recipient_accepted).to be(true)
      expect(result.resolved_queue).to eq("example.queue")
      expect(result.transcript).to include("220 mx.example.net ESMTP")
      expect(smtp).not_to have_received(:send_message)
      expect(endpoint).to have_received(:reset_smtp_session)
    end

    it "rejects an invalid recipient before DNS or SMTP work" do
      result = described_class.new(recipient: "not-an-address").call

      expect(result.connected).to be(false)
      expect(result.summary).to match(/recipient address/i)
      expect(DNSResolver).not_to have_received(:local)
    end

    it "returns the remote SMTP rejection and still reports a successful connection" do
      allow(smtp).to receive(:rcptto).and_raise(Net::SMTPFatalError, "550 5.1.1 User unknown")

      result = described_class.new(recipient: "user@example.net").call

      expect(result.connected).to be(true)
      expect(result.recipient_accepted).to be(false)
      expect(result.summary).to include("550 5.1.1 User unknown")
      expect(result.transcript).to include("Net::SMTPFatalError")
    end
  end

end
