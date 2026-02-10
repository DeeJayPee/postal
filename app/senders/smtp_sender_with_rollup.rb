# frozen_string_literal: true

# Extended SMTP Sender with rollup support
# This class extends the base SMTPSender to add PowerMTA-style rollup functionality
class SMTPSenderWithRollup < SMTPSender

  attr_reader :queue_config, :virtual_queue_name

  def initialize(domain, source_ip_address = nil, servers: nil, log_id: nil, rcpt_to: nil)
    # Resolve virtual queue configuration first to check for backoff IP override
    @virtual_queue_name = SMTPRollupService.resolve_virtual_queue(domain)
    @queue_config = SMTPRollupService.queue_configuration_for_domain(domain) if @virtual_queue_name

    # Override source IP if backoff-reroute-to is configured
    if @queue_config&.backoff_ip_address
      source_ip_address = @queue_config.backoff_ip_address
      logger.info "Using backoff reroute IP: #{source_ip_address}" if defined?(logger)
    end

    super(domain, source_ip_address, servers: servers, log_id: log_id, rcpt_to: rcpt_to)

    if @virtual_queue_name
      logger.info "Using virtual queue '#{@virtual_queue_name}' for domain #{domain}"
      logger.info "Queue config: min=#{@queue_config&.min_smtp_out}, max=#{@queue_config&.max_smtp_out}" if @queue_config
      if @queue_config&.max_msg_rate
        logger.info "Rate limit: #{@queue_config.max_msg_rate}"
      end
    end
  end

  # Override start to respect queue configuration limits
  def start
    servers = @servers || self.class.smtp_relays || resolve_mx_records_for_domain || []

    # Limit the number of servers we try based on queue configuration
    max_connections = @queue_config&.effective_max_smtp_out || servers.size
    servers_to_try = servers.take(max_connections)

    servers_to_try.each do |server|
      server.endpoints.each do |endpoint|
        result = connect_to_endpoint(endpoint)
        return endpoint if result
      end
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

    can_send = @queue_config.can_send_message?
    unless can_send
      logger.warn "Rate limit reached for queue #{@virtual_queue_name} (#{@queue_config.max_msg_rate})"
    end
    can_send
  end

  private

  # Override to log rollup information and check rate limits
  def send_message_to_smtp_client(raw_message, mail_from, rcpt_to, retry_on_connection_error: true)
    # Check rate limit before sending
    unless can_send?
      raise "Rate limit exceeded for queue #{@virtual_queue_name}"
    end

    if @virtual_queue_name
      logger.info "Sending via virtual queue: #{@virtual_queue_name}"
    end

    super(raw_message, mail_from, rcpt_to, retry_on_connection_error: retry_on_connection_error)
  end
end
