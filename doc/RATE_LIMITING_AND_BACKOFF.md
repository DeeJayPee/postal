# Rate Limiting, Queue Backoff Mode and Backoff Rerouting

This document explains `max-msg-rate`, queue `mode` (`normal`/`backoff`), global backoff rules, and `backoff-reroute-to` behavior.

## Overview

These features provide PowerMTA-style queue control for virtual queues:

- **`max-msg-rate`**: Time-based message rate limiting per queue (defer/retry in queue)
- **`mode`**: Queue mode (`normal` or `backoff`)
- **`backoff-reroute-to`**: Alternative relay used only while queue is in `backoff` mode
- **Global backoff rules**: Imported SMTP reply patterns that switch queues to backoff or bounce recipients

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
3. If the limit is reached, sending is deferred (soft-fail) and retried later from the same queue
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

## Queue Mode (`normal` / `backoff`)

Queues can run in two modes:

- `normal`: default behavior
- `backoff`: gentler delivery pacing with larger retry separation

When in backoff mode, retry delays use exponential retry with a queue-specific base delay (default 2 hours).

Optional automatic return to normal mode can be configured using:

```
backoff-auto-success-threshold <number>
backoff-auto-success-window <number><d|h|m|s>
```

## backoff-reroute-to

### Purpose
Specify an alternative SMTP relay server to route messages through for a specific virtual queue. This is useful for:
- Routing throttled traffic through a different relay
- ISP-specific relay routing
- Load balancing across multiple relay servers
- Using dedicated relays for specific destinations

### Format
```
backoff-reroute-to <hostname_or_ip>
```

Supports hostnames, IPv4, and IPv6 addresses.

### Examples
```
backoff-reroute-to relay.example.com
backoff-reroute-to 192.168.1.100
backoff-reroute-to 10.0.0.50
backoff-reroute-to [2001:db8::1]
```

### How It Works

1. Queue is in `backoff` mode
2. `backoff-reroute-to` is configured
3. SMTP sender uses the configured relay server for that queue while it remains in backoff

`backoff-reroute-to` is not used just because `max-msg-rate` threshold is hit.

### Configuration Example
```
<domain throttled.queue>
    min-smtp-out 1
    max-smtp-out 1
    max-rcpt-per-message 50
    backoff-reroute-to relay.backup.example.com
</domain>
```

While the queue is in `backoff` mode, messages for `throttled.queue` are routed through `relay.backup.example.com`.

## Combined Usage

You can use both features together for comprehensive queue management:

```
<domain strict-isp.queue>
    min-smtp-out 1
    max-smtp-out 2
    max-rcpt-per-message 50
    max-msg-rate 500/h
    mode normal
    backoff-base-delay 2h
    backoff-reroute-to 192.168.1.200
</domain>
```

This configuration:
- Limits concurrent connections to 2
- Limits recipients per message to 50
- Limits total messages to 500 per hour (deferred/retried in queue when exceeded)
- Uses relay `192.168.1.200` only if the queue is switched into `backoff` mode

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
    backoff-base-delay 2h
    backoff-reroute-to 10.0.0.100
</domain>
```

### 3. Relay Segregation
Use different relay servers for different ISPs:

```
<domain gmail.queue>
    mode backoff
    backoff-reroute-to relay-gmail.example.com
</domain>

<domain yahoo.queue>
    mode backoff
    backoff-reroute-to relay-yahoo.example.com
</domain>
```

### 4. Throttling Response
When an ISP starts throttling, imported backoff rules switch queue mode to `backoff` and routing can move to backup relay:

```
<domain throttled.queue>
    max-smtp-out 1
    max-msg-rate 100/h
    mode normal
    backoff-base-delay 2h
    backoff-reroute-to backup-relay.example.com
</domain>
```

And global rules in `backoff_rules.conf`:

```
<smtp-pattern-list blocking-errors>
    reply /421 .* Please try again later/ mode=backoff
    reply /OverQuotaTemp/ bounce-rcpt
</smtp-pattern-list>
```

## Database Schema

The `queue_configurations` table includes:

```ruby
t.string :max_msg_rate           # Format: "2000/h", "100/m", "10/s"
t.string :backoff_reroute_to     # IP address (IPv4 or IPv6)
t.string :mode                   # normal or backoff
t.integer :backoff_base_delay_seconds
t.integer :backoff_auto_success_threshold
t.integer :backoff_auto_success_window_seconds
```

## Validation

### max_msg_rate
- Must match format: `\d+/(d|h|m|s)`
- Examples: `10000/d`, `2000/h`, `100/m`, `10/s`
- Invalid: `2000`, `100/hour`, `abc/h`

### backoff_reroute_to
- Must be a valid hostname or IP address
- Examples: `relay.example.com`, `192.168.1.1`, `10.0.0.1`, `[2001:db8::1]`
- Invalid: `not a valid hostname`, `999.999.999.999`

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

### Verify Backoff Relay
```ruby
config = QueueConfiguration.find_by(queue_name: 'throttled.queue')
config.mode
# => "backoff" or "normal"
relay = config.backoff_relay_server
# => "relay.example.com"
```

## Logging

The system logs queue mode, rate limiting, and backoff relay usage:

```
INFO  Using backoff relay server: 192.168.1.100
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

### Backoff Relay Not Being Used
1. Verify queue mode is `backoff`: `bundle exec rails runner 'puts QueueConfiguration.find_by(queue_name: "your.queue").mode'`
2. Verify relay is configured: `bundle exec rails runner 'puts QueueConfiguration.find_by(queue_name: "your.queue").backoff_reroute_to'`
3. Check logs for "Using backoff relay server" message

### Messages Still Being Sent Despite Rate Limit
1. Check if messages are in the correct virtual queue
2. Verify the time window calculation
3. Confirm messages are deferred (SoftFail/retry) instead of rerouted
4. Check for multiple queue configurations with the same name
