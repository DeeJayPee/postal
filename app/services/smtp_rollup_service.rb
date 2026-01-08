# frozen_string_literal: true

# Service to handle SMTP rollup resolution for virtual domain queues
class SMTPRollupService

  # Resolve the virtual queue name for a given recipient domain
  # This considers both domain macros and MX rollups
  #
  # @param domain [String] the recipient domain
  # @return [String, nil] the virtual queue name or nil
  def self.resolve_virtual_queue(domain)
    return nil if domain.blank?

    # First check if the domain matches a domain macro
    queue_name = DomainMacro.find_queue_for_domain(domain)
    return queue_name if queue_name.present?

    # If no macro match, check if the domain has MX records that match a rollup
    resolve_queue_from_mx_rollup(domain)
  end

  # Resolve queue name based on MX rollup configuration
  #
  # @param domain [String] the recipient domain
  # @return [String, nil] the rollup queue name or nil
  def self.resolve_queue_from_mx_rollup(domain)
    mx_records = DNSResolver.local.mx(domain, raise_timeout_errors: false)
    return nil if mx_records.empty?

    # Check each MX record to see if it matches a rollup
    mx_records.each do |_priority, hostname|
      rollup_name = MXRollup.find_rollup_for_mx(hostname)
      return rollup_name if rollup_name.present?
    end

    nil
  rescue StandardError => e
    Postal.logger.error "Error resolving MX rollup for #{domain}: #{e.message}"
    nil
  end

  # Get the queue configuration for a domain
  #
  # @param domain [String] the recipient domain
  # @return [QueueConfiguration, nil] the queue configuration or nil
  def self.queue_configuration_for_domain(domain)
    queue_name = resolve_virtual_queue(domain)
    return nil unless queue_name

    QueueConfiguration.find_for_queue(queue_name)
  end

  # Resolve the actual MX servers to use for a domain, considering rollups
  # This returns the rollup name if one exists, otherwise the original domain
  #
  # @param domain [String] the recipient domain
  # @return [String] the domain or rollup name to use for MX resolution
  def self.resolve_mx_domain(domain)
    rollup_name = resolve_queue_from_mx_rollup(domain)

    # If we have a rollup, we should still use the original MX records
    # but we'll use the rollup name for queue management
    domain
  end

  # Get the batch key for a message considering rollups
  # This is used to group messages in the same virtual queue
  #
  # @param domain [String] the recipient domain
  # @return [String] the batch key
  def self.batch_key_for_domain(domain)
    queue_name = resolve_virtual_queue(domain)
    queue_name || domain
  end

  # Check if a domain should use rollup-based queuing
  #
  # @param domain [String] the recipient domain
  # @return [Boolean] true if rollup queuing should be used
  def self.use_rollup_queuing?(domain)
    resolve_virtual_queue(domain).present?
  end

  # Get all domains that belong to a specific rollup/queue
  #
  # @param queue_name [String] the queue name
  # @return [Array<String>] array of domains
  def self.domains_for_queue(queue_name)
    domains = []

    # Get domains from macros
    DomainMacro.enabled.each do |macro|
      domains.concat(macro.domain_list) if macro.queue_name == queue_name
    end

    # Get domains from MX rollups
    # This is more complex as we'd need to reverse-lookup which domains
    # have MX records pointing to the rollup's MX servers

    domains.uniq
  end
end
