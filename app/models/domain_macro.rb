# frozen_string_literal: true

# == Schema Information
#
# Table name: domain_macros
#
#  id         :integer          not null, primary key
#  name       :string(255)      not null
#  domains    :text(65535)      not null
#  queue_name :string(255)
#  enabled    :boolean          default(TRUE)
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

class DomainMacro < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :domains, presence: true

  scope :enabled, -> { where(enabled: true) }

  # Get array of domains from comma-separated string
  def domain_list
    domains.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  # Set domains from array
  def domain_list=(list)
    self.domains = list.join(",")
  end

  # Check if a domain matches this macro
  def matches_domain?(domain)
    domain_list.include?(domain)
  end

  # Find queue name for a given domain
  def self.find_queue_for_domain(domain)
    enabled.find { |macro| macro.matches_domain?(domain) }&.queue_name
  end

  # Import from PowerMTA-style configuration
  def self.import_from_config(config_text)
    config_text.each_line do |line|
      next if line.strip.start_with?("#") || line.strip.empty?

      if line =~ /^\s*domain-macro\s+(\S+)\s+(.+)/
        name = ::Regexp.last_match(1)
        domains_str = ::Regexp.last_match(2)

        find_or_create_by(name: name) do |macro|
          macro.domains = domains_str
        end
      elsif line =~ /^\s*queue-to\s+(\S+)/
        queue_name = ::Regexp.last_match(1)
        # This would be set on the last created macro
      end
    end
  end
end
