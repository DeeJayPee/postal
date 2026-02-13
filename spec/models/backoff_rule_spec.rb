# frozen_string_literal: true

require "rails_helper"

RSpec.describe BackoffRule do
  describe ".import_from_config" do
    it "imports mode=backoff and bounce-rcpt rules from a smtp-pattern-list" do
      config = <<~CONF
        <smtp-pattern-list blocking-errors>
          reply /421 .* Please try again later/ mode=backoff
          reply /OverQuotaTemp/ bounce-rcpt
        </smtp-pattern-list>
      CONF

      expect { described_class.import_from_config(config) }.to change(described_class, :count).by(2)
      expect(described_class.find_by(pattern: "421 .* Please try again later")&.action).to eq("mode=backoff")
      expect(described_class.find_by(pattern: "OverQuotaTemp")&.action).to eq("bounce-rcpt")
    end
  end

  describe ".match_for_response" do
    it "returns the first matching enabled rule" do
      described_class.create!(pattern: "rate limit", action: "mode=backoff", enabled: true)
      described_class.create!(pattern: "OverQuotaTemp", action: "bounce-rcpt", enabled: true)

      expect(described_class.match_for_response("421 temporary rate limit reached")&.action).to eq("mode=backoff")
      expect(described_class.match_for_response("Mailbox OverQuotaTemp")&.action).to eq("bounce-rcpt")
      expect(described_class.match_for_response("everything good")).to be_nil
    end
  end
end
