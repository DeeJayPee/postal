# frozen_string_literal: true

require "ipaddr"
require "stringio"

# Sends a real diagnostic message through a selected queue and captures the
# complete SMTP protocol transcript for an administrator.
class SMTPConnectionProbe

  MAX_TRANSCRIPT_BYTES = 64.kilobytes

  Result = Struct.new(
    :connected,
    :recipient_accepted,
    :summary,
    :transcript,
    :endpoint,
    :recipient_domain,
    :resolved_queue,
    :requested_queue,
    keyword_init: true
  )

  def initialize(recipient:, queue_name: nil, mail_from: nil)
    @recipient = recipient.to_s.strip
    @requested_queue = queue_name.to_s.strip.presence
    @mail_from = mail_from.to_s.strip
    @transcript = StringIO.new
  end

  def call
    return invalid_result("Select an enabled queue to test.") unless @requested_queue
    return invalid_result("Enter a recipient address in the form user@example.com.") unless valid_address?(@recipient)
    return invalid_result("Enter a MAIL FROM address in the form sender@example.com.") unless valid_address?(@mail_from)

    domain = @recipient.split("@", 2).last.downcase
    resolved_queue = SMTPRollupService.resolve_virtual_queue(domain)
    queue_config = QueueConfiguration.find_for_queue(@requested_queue)
    return invalid_result("The selected queue is not enabled.") unless queue_config

    servers, route_description = servers_for(domain, queue_config)

    append_line("Recipient domain: #{domain}")
    append_line("Resolved virtual queue: #{resolved_queue || '(rest)'}")
    append_line("Selected queue: #{@requested_queue}")
    append_line("Route: #{route_description}")

    if @requested_queue && resolved_queue != @requested_queue
      append_line("WARNING: #{domain} currently resolves to #{resolved_queue || '(rest)'}, not #{@requested_queue}.")
    end

    return result(false, nil, "No SMTP servers were found for #{domain}.", domain, resolved_queue) if servers.empty?

    servers.each do |server|
      endpoints_for(server).each do |endpoint|
        append_line("")
        append_line("--- Connecting to #{endpoint} ---")

        probe_result = probe_endpoint(endpoint, domain, resolved_queue)
        return probe_result if probe_result
      end
    end

    result(false, nil, "Could not establish an SMTP session with any endpoint.", domain, resolved_queue)
  rescue StandardError => e
    append_line("#{e.class}: #{e.message}")
    result(false, nil, "SMTP probe failed: #{e.message}", @recipient.split("@", 2).last, nil)
  end

  private

  def servers_for(domain, queue_config)
    if queue_config&.backoff_relay_server
      relay = queue_config.backoff_relay_server
      return [[SMTPClient::Server.new(relay)], "backoff relay #{relay}"]
    end

    if SMTPSender.smtp_relays.present?
      return [SMTPSender.smtp_relays, "configured global SMTP relay"]
    end

    hostnames = DNSResolver.local.mx(domain, raise_timeout_errors: true).map(&:last)
    hostnames = [domain] if hostnames.empty?
    [hostnames.map { |hostname| SMTPClient::Server.new(hostname) }, "recipient MX"]
  end

  def endpoints_for(server)
    if ip_address?(server.hostname)
      [SMTPClient::Endpoint.new(server, server.hostname.delete_prefix("[").delete_suffix("]"))]
    else
      server.endpoints
    end
  end

  def probe_endpoint(endpoint, domain, resolved_queue)
    recipient_accepted = false
    begin
      smtp = endpoint.start_smtp_session(debug_output: @transcript)
    rescue OpenSSL::SSL::SSLError => e
      raise unless endpoint.server.ssl_mode == SMTPClient::SSLModes::AUTO

      append_line("TLS negotiation failed (#{e.message}); retrying without STARTTLS.")
      endpoint.finish_smtp_session
      smtp = endpoint.start_smtp_session(allow_ssl: false, debug_output: @transcript)
    end

    smtp.mailfrom(@mail_from)
    smtp.rcptto(@recipient)
    recipient_accepted = true
    response = smtp.data(diagnostic_message)
    append_line("Message accepted: #{response.string.to_s.strip}")
    result(true, true, "The diagnostic email was accepted for delivery.", domain, resolved_queue, endpoint)
  rescue Net::SMTPError => e
    append_line("#{e.class}: #{e.message}")
    if recipient_accepted
      summary = "SMTP accepted RCPT TO, but rejected the diagnostic message DATA: #{e.message}"
    else
      summary = "SMTP connected, but rejected the diagnostic recipient: #{e.message}"
    end
    result(true, recipient_accepted, summary, domain, resolved_queue, endpoint)
  rescue StandardError => e
    append_line("#{e.class}: #{e.message}")
    nil
  ensure
    endpoint.reset_smtp_session if smtp
    endpoint.finish_smtp_session
  end

  def result(connected, recipient_accepted, summary, domain, resolved_queue, endpoint = nil)
    Result.new(
      connected: connected,
      recipient_accepted: recipient_accepted,
      summary: summary,
      transcript: limited_transcript,
      endpoint: endpoint&.to_s,
      recipient_domain: domain,
      resolved_queue: resolved_queue,
      requested_queue: @requested_queue
    )
  end

  def invalid_result(message)
    result(false, nil, message, nil, nil)
  end

  def limited_transcript
    value = @transcript.string.scrub
    return value if value.bytesize <= MAX_TRANSCRIPT_BYTES

    "#{value.byteslice(0, MAX_TRANSCRIPT_BYTES).scrub}\n[transcript truncated]"
  end

  def append_line(line)
    @transcript.puts(line)
  end

  def valid_address?(address)
    address.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
  end

  def diagnostic_message
    message = Mail.new
    message.from = @mail_from
    message.to = @recipient
    message.subject = "Postal queue diagnostic for #{@requested_queue}"
    message.date = Time.current
    message.message_id = "<#{SecureRandom.uuid}@#{@mail_from.split('@', 2).last}>"
    message.body = "This is a real delivery diagnostic sent by Postal for queue #{@requested_queue} at #{Time.current.utc.iso8601}."
    message.to_s
  end

  def ip_address?(hostname)
    IPAddr.new(hostname.to_s.delete_prefix("[").delete_suffix("]"))
    true
  rescue IPAddr::InvalidAddressError
    false
  end

end
