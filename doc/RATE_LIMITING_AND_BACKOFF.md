# Rate Limiting and Backoff IP Rerouting

This document explains the `max-msg-rate` and `backoff-reroute-to` features added to the SMTP rollup queue configurations.

## Overview

These features provide PowerMTA-style rate limiting and IP rerouting capabilities for virtual queues:

- **`max-msg-rate`**: Time-based message rate limiting per queue
- **`backoff-reroute-to`**: Alternative IP address for throttled/backoff scenarios

## max-msg-rate

### Purpose
Limit the number of messages sent through a virtual queue over a specific time period to avoid ISP rate limits and throttling.

### Format
```
max-msg-rate <number>/<unit>
```

Where `<unit>` can be:
- `d` - per day
- `h` - per hour
- `m` - per minute
- `s` - per second

### Examples
```
max-msg-rate 10000/d  # 10000 messages per day
max-msg-rate 2000/h   # 2000 messages per hour
max-msg-rate 100/m    # 100 messages per minute
max-msg-rate 10/s     # 10 messages per second
```

### How It Works

1. When a message is about to be sent via `SMTPSenderWithRollup`, the system checks if the queue has a `max-msg-rate` configured
2. It counts messages sent through that virtual queue in the configured time window
3. If the limit is reached, sending is blocked with a rate limit error
4. The counter resets based on the sliding time window

### Configuration Example
```
<domain orange.queue>
    min-smtp-out 1
    max-smtp-out 1
    max-rcpt-per-message 100
    max-msg-rate 2000/h
</domain>
```

This limits the `orange.queue` to 2000 messages per hour.

## backoff-reroute-to

### Purpose
Specify an alternative IP address to use when sending through a specific virtual queue. This is useful for:
- ISP-specific IP reputation management
- Throttling scenarios where you want to use a different IP
- Segregating traffic by queue to different source IPs

### Format
```
backoff-reroute-to <ip_address>
```

Supports both IPv4 and IPv6 addresses.

### Examples
```
backoff-reroute-to 192.168.1.100
backoff-reroute-to 10.0.0.50
backoff-reroute-to 2001:db8::1
```

### How It Works

1. When `SMTPSenderWithRollup` is initialized for a domain with a queue configuration
2. If `backoff-reroute-to` is set, it overrides the source IP address for all connections
3. All SMTP connections for that virtual queue will originate from the specified IP
4. This happens before the SMTP session starts

### Configuration Example
```
<domain throttled.queue>
    min-smtp-out 1
    max-smtp-out 1
    max-rcpt-per-message 50
    backoff-reroute-to 10.0.0.50
</domain>
```

All messages sent through `throttled.queue` will use `10.0.0.50` as the source IP.

## Combined Usage

You can use both features together for comprehensive queue management:

```
<domain strict-isp.queue>
    min-smtp-out 1
    max-smtp-out 2
    max-rcpt-per-message 50
    max-msg-rate 500/h
    backoff-reroute-to 192.168.1.200
</domain>
```

This configuration:
- Limits concurrent connections to 2
- Limits recipients per message to 50
- Limits total messages to 500 per hour
- Uses IP `192.168.1.200` for all connections

## Use Cases

### 1. ISP Rate Limiting Compliance
Some ISPs have strict hourly message limits:

```
<domain strict-isp.queue>
    max-msg-rate 1000/h
</domain>
```

### 2. Gradual Warmup
When warming up a new IP, start with low rates:

```
<domain warmup.queue>
    max-smtp-out 1
    max-msg-rate 50/h
    backoff-reroute-to 10.0.0.100
</domain>
```

### 3. IP Reputation Segregation
Use different IPs for different ISPs:

```
<domain gmail.queue>
    backoff-reroute-to 192.168.1.10
</domain>

<domain yahoo.queue>
    backoff-reroute-to 192.168.1.20
</domain>
```

### 4. Throttling Response
When an ISP starts throttling, reduce rate and switch IP:

```
<domain throttled.queue>
    max-smtp-out 1
    max-msg-rate 100/h
    backoff-reroute-to 10.0.0.50
</domain>
```

## Database Schema

The `queue_configurations` table includes:

```ruby
t.string :max_msg_rate           # Format: "2000/h", "100/m", "10/s"
t.string :backoff_reroute_to     # IP address (IPv4 or IPv6)
```

## Validation

### max_msg_rate
- Must match format: `\d+/(d|h|m|s)`
- Examples: `10000/d`, `2000/h`, `100/m`, `10/s`
- Invalid: `2000`, `100/hour`, `abc/h`

### backoff_reroute_to
- Must be a valid IP address (IPv4 or IPv6)
- Examples: `192.168.1.1`, `10.0.0.1`, `2001:db8::1`
- Invalid: `not-an-ip`, `999.999.999.999`

## Monitoring

### Check Rate Limit Status
```ruby
config = QueueConfiguration.find_by(queue_name: 'orange.queue')
rate = config.parsed_max_msg_rate
# => { count: 2000, period: 3600, per_second: 0.555... }

can_send = config.can_send_message?
# => true or false
```

### Check Messages Sent
```sql
-- Messages sent in last hour for a queue
SELECT COUNT(*)
FROM queued_messages
WHERE virtual_queue = 'orange.queue'
  AND created_at >= NOW() - INTERVAL 1 HOUR;
```

### Verify Backoff IP
```ruby
config = QueueConfiguration.find_by(queue_name: 'throttled.queue')
ip = config.backoff_ip_address
# => #<IPAddress::IPv4:...>
```

## Logging

The system logs rate limiting and IP rerouting activity:

```
INFO  Using backoff reroute IP: 192.168.1.100
INFO  Rate limit: 2000/h
WARN  Rate limit reached for queue orange.queue (2000/h)
```

## Migration from PowerMTA

PowerMTA users can migrate their configurations:

### PowerMTA Config
```
<domain example.com>
    max-msg-rate 2000/h
    backoff-reroute-to 192.168.1.100
</domain>
```

### Postal Config
```
<domain example.queue>
    max-msg-rate 2000/h
    backoff-reroute-to 192.168.1.100
</domain>
```

The syntax is identical for these parameters.

## Best Practices

1. **Start Conservative**: Begin with lower rates and increase based on ISP feedback
2. **Monitor Bounces**: Watch for rate limiting responses from ISPs
3. **Use Separate IPs**: Consider using different IPs for different ISP categories
4. **Document Changes**: Keep track of rate limits and IP assignments
5. **Test Thoroughly**: Test with small volumes before applying to production

## Troubleshooting

### Rate Limit Not Working
1. Check the format: `bundle exec rails runner 'puts QueueConfiguration.find_by(queue_name: "your.queue").max_msg_rate'`
2. Verify validation: `bundle exec rails runner 'config = QueueConfiguration.find_by(queue_name: "your.queue"); config.valid?; puts config.errors.full_messages'`
3. Check logs for rate limit warnings

### Backoff IP Not Being Used
1. Verify IP is valid: `bundle exec rails runner 'puts QueueConfiguration.find_by(queue_name: "your.queue").backoff_ip_address'`
2. Check logs for "Using backoff reroute IP" message
3. Ensure the IP exists on your server: `ip addr show`

### Messages Still Being Sent Despite Rate Limit
1. Check if messages are in the correct virtual queue
2. Verify the time window calculation
3. Check for multiple queue configurations with the same name
