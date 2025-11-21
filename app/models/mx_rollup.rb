# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rollups
#
#  id          :integer          not null, primary key
#  mx_hostname :string(255)      not null
#  rollup_name :string(255)      not null
#  description :text(65535)
#  enabled     :boolean          default(TRUE)
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#

class MxRollup < ApplicationRecord
  validates :mx_hostname, presence: true
  validates :rollup_name, presence: true

  scope :enabled, -> { where(enabled: true) }

  # Find rollup name for a given MX hostname
  def self.find_rollup_for_mx(mx_hostname)
    enabled.find_by(mx_hostname: mx_hostname)&.rollup_name
  end

  # Import rollups from PowerMTA-style configuration
  def self.import_from_config(config_text)
    config_text.each_line do |line|
      next if line.strip.start_with?("#") || line.strip.empty?

      if line =~ /^\s*mx\s+(\S+)\s+(\S+)/
        mx_hostname = ::Regexp.last_match(1)
        rollup_name = ::Regexp.last_match(2)

        find_or_create_by(mx_hostname: mx_hostname) do |rollup|
          rollup.rollup_name = rollup_name
        end
      end
    end
  end
end
