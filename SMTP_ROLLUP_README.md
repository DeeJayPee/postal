# SMTP Rollup Feature for Postal

This implementation adds PowerMTA-style SMTP rollup functionality to Postal, enabling virtual domain queue management for better email delivery control.

## What's New

This feature adds three main capabilities to Postal:

1. **MX Rollups**: Automatically group domains by their MX servers into virtual queues
2. **Domain Macros**: Explicitly group multiple domains into virtual queues
3. **Queue Configurations**: Set SMTP connection and message limits per virtual queue

## Files Added

### Database Migrations
- `db/migrate/20241121000001_create_mx_rollups.rb` - MX rollup table
- `db/migrate/20241121000002_create_domain_macros.rb` - Domain macro table
- `db/migrate/20241121000003_create_queue_configurations.rb` - Queue configuration table
- `db/migrate/20241121000004_add_virtual_queue_to_queued_messages.rb` - Virtual queue field

### Models
- `app/models/mx_rollup.rb` - MX rollup model
- `app/models/domain_macro.rb` - Domain macro model
- `app/models/queue_configuration.rb` - Queue configuration model

### Services
- `app/services/smtp_rollup_service.rb` - Core rollup resolution logic

### Senders
- `app/senders/smtp_sender_with_rollup.rb` - Extended SMTP sender with rollup support

### Tasks
- `lib/tasks/smtp_rollup.rake` - Rake tasks for import/export/management

### Configuration
- `config/initializers/smtp_rollup.rb` - Initializer
- `config/examples/mx_rollups.conf` - Example MX rollup configuration
- `config/examples/domain_macros.conf` - Example domain macro configuration
- `config/examples/queue_configs.conf` - Example queue configuration
- `config/examples/backoff_rules.conf` - Global SMTP backoff rule configuration

### Documentation
- `doc/smtp_rollup_guide.md` - Comprehensive user guide
- `bin/setup_smtp_rollup` - Setup script

### Modified Files
- `lib/postal/message_db/message.rb` - Updated to use virtual queues in batch_key and add_to_message_queue
- `app/lib/message_dequeuer/outgoing_message_processor.rb` - Updated to use SMTPSenderWithRollup

## Quick Start

### 1. Run Migrations

```bash
bundle exec rails db:migrate
```

### 2. Import Example Configurations

```bash
# Copy example files
cp config/examples/mx_rollups.conf config/
cp config/examples/domain_macros.conf config/
cp config/examples/queue_configs.conf config/
cp config/examples/backoff_rules.conf config/

# Import all configurations
bundle exec rake postal:smtp_rollup:import_all
```

### 3. Verify Setup

```bash
bundle exec rake postal:smtp_rollup:stats
```

## Configuration Examples

### MX Rollup Example

Group all Gmail MX servers into a single virtual queue:

```
# config/mx_rollups.conf
mx aspmx.l.google.com gmail-biz.rollup
mx alt1.aspmx.l.google.com gmail-biz.rollup
mx alt2.aspmx.l.google.com gmail-biz.rollup
```

### Domain Macro Example

Group Orange ISP domains:

```
# config/domain_macros.conf
domain-macro orange orange.fr,wanadoo.fr,orange.rollup
    queue-to orange.queue
```

### Queue Configuration Example

Limit concurrent connections and message rate to Orange:

```
# config/queue_configs.conf
<domain orange.queue>
    min-smtp-out 1
    max-smtp-out 1
    max-rcpt-per-message 100
    max-msg-rate 2000/h
    backoff-reroute-to 192.168.1.100
</domain>
```

## How It Works

### Message Flow

1. **Queuing**: When a message is queued, the system checks if the recipient domain matches:
   - A domain macro (explicit match)
   - An MX rollup (via MX lookup)

2. **Virtual Queue Assignment**: Matching messages are assigned to a virtual queue

3. **Batching**: Messages in the same virtual queue are batched together

4. **Sending**: The `SMTPSenderWithRollup` respects queue configuration limits

### Example Scenario

**Configuration:**
```
# MX Rollup
mx smtp-in.orange.fr orange.rollup

# Domain Macro
domain-macro orange orange.fr,wanadoo.fr,orange.rollup
    queue-to orange.queue

# Queue Config
<domain orange.queue>
    min-smtp-out 1
    max-smtp-out 1
    max-rcpt-per-message 100
</domain>
```

**Result:**
- Email to `user@orange.fr` → Uses `orange.queue`
- Email to `user@wanadoo.fr` → Uses `orange.queue`
- Email to any domain with MX `smtp-in.orange.fr` → Uses `orange.queue`
- All these emails are batched together and sent with max 1 concurrent connection

## Management Commands

Administrators can create and edit queues and MX mappings, inspect runtime sizes,
and run SMTP probes at `/admin/queues`. Queue names remain fixed after creation
so existing mappings and queued messages keep their references.

The queue table separates messages that are ready for a worker, scheduled for a
later retry, and currently locked for delivery. **Retry now** clears the schedule
for unlocked messages in one queue. Entering backoff with a configured relay does
the same automatically so eligible traffic is rerouted without waiting for the
normal backoff delay.

MX mappings are stored on a message when it enters the queue. After adding or
changing a mapping, use **Refresh pending queue assignments** to reclassify
messages that were already in “Rest.” The operation is cursor-batched in groups
of 1,000.

### Add a Queue or MX Rollup

```bash
bundle exec rake 'postal:smtp_rollup:add_queue[orange.queue,1,3,100,2000/h]'
bundle exec rake 'postal:smtp_rollup:add_mx_rollup[smtp-in.orange.fr,orange.queue]'
```

Send a real diagnostic email and print the full SMTP transcript:

```bash
bundle exec rake 'postal:smtp_rollup:probe_smtp[user@orange.fr,orange.queue,probe@example.org]'
```

Preview or apply queue assignment changes to the existing backlog:

```bash
bundle exec rake 'postal:queues:reclassify[all,true,1000]'
bundle exec rake 'postal:queues:reclassify[example.queue,false,1000]'
```

### Import Configurations

```bash
# Import all
bundle exec rake postal:smtp_rollup:import_all

# Import individually
bundle exec rake postal:smtp_rollup:import_mx_rollups[config/mx_rollups.conf]
bundle exec rake postal:smtp_rollup:import_domain_macros[config/domain_macros.conf]
bundle exec rake postal:smtp_rollup:import_queue_configs[config/queue_configs.conf]
bundle exec rake postal:smtp_rollup:import_backoff_rules[config/backoff_rules.conf]
```

### Export Configurations

```bash
bundle exec rake postal:smtp_rollup:export
# Exports to config/rollup_export/
```

### View Statistics

```bash
bundle exec rake postal:smtp_rollup:stats
```

## Database Schema

### mx_rollups
- `mx_hostname` - MX hostname to match
- `rollup_name` - Virtual queue name
- `enabled` - Active status

### domain_macros
- `name` - Macro name
- `domains` - Comma-separated domain list
- `queue_name` - Virtual queue name
- `enabled` - Active status

### queue_configurations
- `queue_name` - Virtual queue name
- `min_smtp_out` - PowerMTA import compatibility; Postal opens connections on demand
- `max_smtp_out` - Maximum concurrent SMTP connections across all workers
- `backoff_max_smtp_out` - Maximum concurrent connections in backoff
- `retry_after` / `backoff_retry_after` - Queue-level connection retry delays
- `max_msg_per_connection` - Bounded delivery quantum per connection
- `mx_connection_attempts` - MX endpoint attempts per scheduler pass
- `max_rcpt_per_message` - Max recipients per message
- `max_msg_rate` - Maximum message rate limit (e.g., 2000/h, 100/m, 10/s)
- `mode` - Queue mode (`normal` or `backoff`)
- `backoff_base_delay_seconds` - Base retry delay used for backoff mode pacing
- `backoff_auto_success_threshold` - Optional success threshold to auto-return to normal mode
- `backoff_auto_success_window_seconds` - Optional success window for auto-return tracking
- `backoff_reroute_to` - Alternative SMTP relay server (hostname or IP), used only in backoff mode
- `enabled` - Active status

### backoff_rules
- `pattern` - Regex pattern matched against SMTP response text
- `action` - `mode=backoff` or `bounce-rcpt`
- `enabled` - Active status

### queued_messages (modified)
- `virtual_queue` - Virtual queue name (new field)

## API Usage

### Programmatic Management

```ruby
# Create MX rollup
MXRollup.create!(
  mx_hostname: 'mx.example.com',
  rollup_name: 'example.rollup'
)

# Create domain macro
DomainMacro.create!(
  name: 'example',
  domains: 'example.com,example.org',
  queue_name: 'example.queue'
)

# Create queue configuration
QueueConfiguration.create!(
  queue_name: 'example.queue',
  min_smtp_out: 1,
  max_smtp_out: 3,
  max_rcpt_per_message: 100
)

# Resolve virtual queue
queue = SMTPRollupService.resolve_virtual_queue('example.com')
```

## Monitoring

### Check Queue Depth

```sql
SELECT virtual_queue, COUNT(*) as message_count
FROM queued_messages
WHERE virtual_queue IS NOT NULL
GROUP BY virtual_queue
ORDER BY message_count DESC;
```

### Check Active Configurations

```sql
SELECT * FROM queue_configurations WHERE enabled = 1;
SELECT rollup_name, COUNT(*) FROM mx_rollups WHERE enabled = 1 GROUP BY rollup_name;
SELECT action, COUNT(*) FROM backoff_rules WHERE enabled = 1 GROUP BY action;
```

## Use Cases

### 1. ISP Throttling
Limit connections to ISPs with strict rate limits:
```
<domain orange.queue>
    max-smtp-out 1
</domain>
```

### 2. Geographic Routing
Separate queues for different regions:
```
mx eur.olc.protection.outlook.com outlook-eur.rollup
mx nam.olc.protection.outlook.com outlook-nam.rollup
```

### 3. Domain Grouping
Treat related domains as one destination:
```
domain-macro microsoft hotmail.com,outlook.com,live.com
    queue-to microsoft.queue
```

## Troubleshooting

### Messages Not Using Rollup

1. Check if rollup is enabled:
```sql
SELECT * FROM mx_rollups WHERE mx_hostname = 'your.mx.hostname';
```

2. Check logs:
```bash
grep "virtual queue" /var/log/postal/postal.log
```

### Connection Limits Not Applied

1. Verify queue configuration exists and is enabled
2. Check that messages have `virtual_queue` field set
3. Verify `SMTPSenderWithRollup` is being used (check logs)

## Best Practices

1. **Start Conservative**: Begin with low connection limits
2. **Monitor Bounces**: Watch for rate limiting responses
3. **Test First**: Test with small volume before production
4. **Keep Updated**: Maintain MX rollup lists as ISPs change infrastructure
5. **Document Changes**: Keep track of configuration changes

## Migration from PowerMTA

The configuration format is intentionally similar to PowerMTA for easier migration:

1. Export PowerMTA virtual-mta and domain configurations
2. Convert to Postal format (minimal changes needed)
3. Import using rake tasks
4. Test and monitor

## Performance Considerations

- MX lookups are cached by DNSResolver
- Virtual queue resolution happens once during message queuing
- Batching improves throughput for high-volume queues
- Connection pooling reduces overhead

## Security Notes

- All configuration is stored in the database
- Configuration files are only used for import/export
- No external dependencies required
- Standard Postal security practices apply

## Support

For issues or questions:
1. Check the comprehensive guide: `doc/smtp_rollup_guide.md`
2. Review configuration examples in `config/examples/`
3. Check Postal logs for rollup-related messages
4. Verify database records are correct

## Future Enhancements

Potential future improvements:
- Disable existing queues and rollups from the web UI
- Real-time queue statistics dashboard
- Automatic MX rollup discovery
- Rate limiting per queue
- Time-based queue rules
- API endpoints for configuration management

## Credits

This implementation is inspired by PowerMTA's virtual MTA and domain configuration system, adapted for Postal's architecture.
