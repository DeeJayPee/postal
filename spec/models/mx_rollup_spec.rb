# frozen_string_literal: true

require "rails_helper"

RSpec.describe MXRollup do

  describe "normalization" do
    it "stores MX hostnames in the same form returned by the DNS resolver" do
      rollup = described_class.create!(
        mx_hostname: "MX.Example.NET.",
        rollup_name: " example.queue "
      )

      expect(rollup.mx_hostname).to eq("mx.example.net")
      expect(rollup.rollup_name).to eq("example.queue")
      expect(described_class.find_rollup_for_mx("MX.EXAMPLE.NET.")).to eq("example.queue")
    end
  end

end
