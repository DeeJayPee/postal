# frozen_string_literal: true

# Extended SMTP Sender with rollup support
# This class extends the base SMTPSender to add PowerMTA-style rollup functionality
class SMTPSenderWithRollup < SMTPSender

  attr_reader :queue_config, :virtual_queue_name

  def initialize(domain, source_ip_address = nil, servers: nil, log_id: nil, rcpt_to: nil, queue_name: nil,
                 mx_attempt_offset: 0)
    # A queued message's stored assignment is authoritative. DNS is only used
    # when a sender is created outside the queue processor.
    @virtual_queue_name = queue_name.presence || SMTPRollupService.resolve_virtual_queue(domain)
    @queue_config = QueueConfiguration.find_for_queue(@virtual_queue_name) if @virtual_queue_name
    @mx_attempt_offset = mx_attempt_offset.to_i
    @use_backoff_relay = false  # Track if we should use backoff relay

    super(domain, source_ip_address, servers: servers, log_id: log_id, rcpt_to: rcpt_to)

    if @virtual_queue_name
      logger.info "Using virtual queue '#{@virtual_queue_name}' for domain #{domain}"
      logger.info "Queue config: min=#{@queue_config&.min_smtp_out}, max=#{@queue_config&.max_smtp_out}" if @queue_config
      if @queue_config&.max_msg_rate
        logger.info "Rate limit: #{@queue_config.max_msg_rate}"
      end
      if @queue_config&.backoff_relay_server
        logger.info "Backoff relay available: #{@queue_config.backoff_relay_server}"
      end
    end
  end

  # Override start to respect queue configuration limits
  def start
    # Check if we should use backoff relay (backoff mode only)
    if should_use_backoff_relay?
      @use_backoff_relay = true
      relay_host = @queue_config.backoff_relay_server
      logger.info "Using backoff relay server: #{relay_host}"
      servers = [SMTPClient::Server.new(relay_host)]
    else
      # Normal routing: use provided servers, global relays, or MX records
      servers = @servers || self.class.smtp_relays || resolve_mx_records_for_domain || []
    end

    if servers.empty?
      logger.error "No servers available to connect to for domain #{@domain}"
      return false
    end

    max_attempts = @queue_config&.effective_mx_connection_attempts
    attempts = 0
    logger.info "Attempting up to #{max_attempts} MX endpoint(s)" if @virtual_queue_name && max_attempts

    rotated_servers = servers.rotate(@mx_attempt_offset % servers.size)
    rotated_servers.each do |server|
      logger.info "Resolving endpoints for server: #{server.hostname}" if @virtual_queue_name

      # Check if the hostname is actually an IP address
      # If so, create endpoint directly instead of doing DNS resolution
      if ip_address?(server.hostname)
        break if max_attempts && attempts >= max_attempts

        logger.info "Server hostname is an IP address, creating endpoint directly" if @virtual_queue_name
        endpoint = SMTPClient::Endpoint.new(server, server.hostname)
        attempts += 1
        result = connect_to_endpoint(endpoint)
        return endpoint if result
      else
        # Normal DNS resolution for hostnames
        endpoints = server.endpoints

        if endpoints.empty?
          logger.warn "No endpoints found for server #{server.hostname}" if @virtual_queue_name
          next
        end

        endpoints.each do |endpoint|
          break if max_attempts && attempts >= max_attempts

          attempts += 1
          result = connect_to_endpoint(endpoint)
          return endpoint if result
        end
      end

      break if max_attempts && attempts >= max_attempts
    end

    false
  end

  # Get the maximum recipients per message from queue config
  def max_rcpt_per_message
    @queue_config&.max_rcpt_per_message || 100
  end

  # Check if we can send based on rate limits
  def can_send?
    return true unless @queue_config

    @rate_decision = @queue_config.reserve_message_attempt
    unless @rate_decision.allowed?
      logger.warn "Rate limit reached for queue #{@virtual_queue_name} (#{@queue_config.max_msg_rate})"
    end
    @rate_decision.allowed?
  end

  # Determine if we should use the backoff relay server
  # Use it only when queue is in backoff mode and backoff-reroute-to is configured.
  def should_use_backoff_relay?
    return false unless @queue_config&.backoff_relay_server

    @queue_config.backoff?
  end

  private

  # Check if a string is an IP address (IPv4 or IPv6)
  def ip_address?(str)
    # IPv4 pattern
    return true if str =~ /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
    # IPv6 pattern (simplified - matches common formats)
    return true if str =~ /^(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$|^::(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4}$|^[0-9a-fA-F]{1,4}::(?:[0-9a-fA-F]{1,4}:){0,5}[0-9a-fA-F]{1,4}$/
    # IPv6 in brackets
    return true if str =~ /^\[.*\]$/

    false
  end

  # Override to log rollup information and check rate limits
  def send_message_to_smtp_client(raw_message, mail_from, rcpt_to, retry_on_connection_error: true)
    # Check rate limit before sending.
    # Over-threshold messages should stay queued and retry later (no reroute fallback).
    unless can_send?
      retry_after = @rate_decision&.retry_after || @queue_config&.rate_limit_retry_seconds || 60
      return create_result("SoftFail") do |r|
        r.retry = retry_after
        r.queue_retry_after = retry_after
        r.details = "Rate limit exceeded for queue #{@virtual_queue_name}; keeping message queued"
        r.output = "Rate limit exceeded (#{@queue_config&.max_msg_rate})"
      end
    end

    if @virtual_queue_name
      logger.info "Sending via virtual queue: #{@virtual_queue_name}"
    end

    super(raw_message, mail_from, rcpt_to, retry_on_connection_error: retry_on_connection_error)
  end
end
