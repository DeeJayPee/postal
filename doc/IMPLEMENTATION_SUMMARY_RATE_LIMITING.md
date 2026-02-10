# Implementation Summary: max-msg-rate and backoff-reroute-to

## Overview
Added PowerMTA-style rate limiting (`max-msg-rate`) and IP rerouting (`backoff-reroute-to`) features to SMTP rollup queue configurations.

## Changes Made

### 1. Database Migration
**File**: `db/migrate/20241121000005_add_rate_limiting_to_queue_configurations.rb`

Added two new columns to `queue_configurations` table:
- `max_msg_rate` (string) - Rate limit in format "number/unit" (e.g., "2000/h")
- `backoff_reroute_to` (string) - IP address for backoff/throttling

### 2. Model Updates
**File**: `app/models/queue_configuration.rb`

**Added Methods**:
- `parsed_max_msg_rate` - Parses rate string into hash with count, period, and per_second
- `can_send_message?` - Checks if message can be sent based on rate limit
- `backoff_ip_address` - Returns parsed IPAddress object for backoff IP
- `validate_max_msg_rate_format` - Validates rate format (number/h|m|s)
- `validate_backoff_reroute_to_format` - Validates IP address format

**Updated Methods**:
- `import_from_config` - Now parses `max-msg-rate` and `backoff-reroute-to` from config files

**Rate Format Support**:
- `/d` - per day (86400 seconds)
- `/h` - per hour (3600 seconds)
- `/m` - per minute (60 seconds)
- `/s` - per second (1 second)

### 3. SMTP Sender Updates
**File**: `app/senders/smtp_sender_with_rollup.rb`

**Modified `initialize`**:
- Checks for `backoff_reroute_to` in queue config
- Overrides source IP address if backoff IP is configured
- Logs backoff IP usage and rate limits

**Modified `can_send?`**:
- Checks rate limit via `queue_config.can_send_message?`
- Logs warning when rate limit is reached

**Added `send_message`**:
- Validates rate limit before sending
- Raises exception if rate limit exceeded

### 4. Configuration File Updates

**File**: `config/examples/queue_configs.conf`
- Added header comments explaining new parameters
- Added example with `max-msg-rate 2000/h`
- Added example with `backoff-reroute-to 192.168.1.100`
- Added example combining both features

**File**: `doc/config/queue_configs.conf`
- Updated header with parameter documentation
- Added real-world examples for Orange and Free queues

### 5. Documentation Updates

**File**: `doc/smtp_rollup_guide.md`
- Added `max-msg-rate` and `backoff-reroute-to` to parameter list
- Updated queue configuration format section
- Added examples showing both parameters
- Updated use cases with rate limiting example
- Updated database schema section

**File**: `SMTP_ROLLUP_README.md`
- Updated queue configuration example
- Added parameters to database schema section

**File**: `doc/RATE_LIMITING_AND_BACKOFF.md` (NEW)
- Comprehensive guide for both features
- Format specifications
- How it works explanations
- Use cases and examples
- Monitoring and troubleshooting
- Migration guide from PowerMTA

## Feature Details

### max-msg-rate

**Purpose**: Time-based message rate limiting per virtual queue

**Format**: `<number>/<unit>` where unit is d (day), h (hour), m (minute), or s (second)

**Examples**:
```
max-msg-rate 10000/d  # 10000 messages per day
max-msg-rate 2000/h   # 2000 messages per hour
max-msg-rate 100/m    # 100 messages per minute
max-msg-rate 10/s     # 10 messages per second
```

**Implementation**:
1. Rate string is parsed into count and period (in seconds)
2. When sending, system counts messages in the virtual queue within the time window
3. If count >= limit, sending is blocked
4. Uses sliding window based on `queued_messages.created_at`

**Database Query**:
```ruby
cutoff_time = Time.current - rate[:period].seconds
sent_count = QueuedMessage.where(virtual_queue: queue_name)
                          .where('created_at >= ?', cutoff_time)
                          .count
```

### backoff-reroute-to

**Purpose**: Override source IP address for specific virtual queues

**Format**: Valid IPv4 or IPv6 address

**Examples**:
```
backoff-reroute-to 192.168.1.100
backoff-reroute-to 10.0.0.50
backoff-reroute-to 2001:db8::1
```

**Implementation**:
1. IP is validated using `IPAddress.parse` during model validation
2. In `SMTPSenderWithRollup#initialize`, backoff IP overrides source_ip_address parameter
3. Override happens before calling `super`, so all SMTP connections use the backoff IP
4. Logged for visibility

## Configuration Example

```
<domain orange.queue>
    min-smtp-out 1
    max-smtp-out 1
    max-rcpt-per-message 100
    max-msg-rate 2000/h
    backoff-reroute-to 192.168.1.100
</domain>
```

This configuration:
- Limits to 1 concurrent connection
- Limits to 100 recipients per message
- Limits to 2000 messages per hour
- Uses IP 192.168.1.100 for all connections

## Usage

### Import Configuration
```bash
# Edit config file
vim config/queue_configs.conf

# Import
bundle exec rake postal:smtp_rollup:import_queue_configs[config/queue_configs.conf]
```

### Verify Configuration
```ruby
config = QueueConfiguration.find_by(queue_name: 'orange.queue')
puts config.max_msg_rate          # "2000/h"
puts config.backoff_reroute_to    # "192.168.1.100"
puts config.parsed_max_msg_rate   # { count: 2000, period: 3600, per_second: 0.555... }
puts config.backoff_ip_address    # #<IPAddress::IPv4:...>
```

### Check Rate Limit Status
```ruby
config = QueueConfiguration.find_by(queue_name: 'orange.queue')
can_send = config.can_send_message?  # true or false
```

## Testing Checklist

- [ ] Run migration: `bundle exec rails db:migrate`
- [ ] Verify columns added: `bundle exec rails runner 'puts QueueConfiguration.column_names'`
- [ ] Test rate format validation: Create config with invalid format
- [ ] Test IP validation: Create config with invalid IP
- [ ] Test rate parsing: Verify `parsed_max_msg_rate` returns correct values
- [ ] Test IP parsing: Verify `backoff_ip_address` returns IPAddress object
- [ ] Test config import: Import file with new parameters
- [ ] Test rate limiting: Send messages and verify limit is enforced
- [ ] Test IP override: Verify backoff IP is used in SMTP connections
- [ ] Check logs: Verify rate limit warnings and IP override messages appear

## Files Modified

### New Files
1. `db/migrate/20241121000005_add_rate_limiting_to_queue_configurations.rb`
2. `doc/RATE_LIMITING_AND_BACKOFF.md`
3. `doc/IMPLEMENTATION_SUMMARY_RATE_LIMITING.md`

### Modified Files
1. `app/models/queue_configuration.rb`
2. `app/senders/smtp_sender_with_rollup.rb`
3. `config/examples/queue_configs.conf`
4. `doc/config/queue_configs.conf`
5. `doc/smtp_rollup_guide.md`
6. `SMTP_ROLLUP_README.md`

## PowerMTA Compatibility

Both parameters use identical syntax to PowerMTA:
- `max-msg-rate 2000/h` - Same format
- `backoff-reroute-to 192.168.1.100` - Same format

This makes migration from PowerMTA straightforward.

## Next Steps

1. Run database migration
2. Test with sample configurations
3. Monitor logs for rate limiting and IP override messages
4. Adjust rate limits based on ISP feedback
5. Document any ISP-specific rate limits discovered
