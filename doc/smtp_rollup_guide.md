# SMTP Rollup Guide for Postal

This guide explains how to use the SMTP rollup feature in Postal, which provides PowerMTA-style virtual domain queuing for better email delivery management.

## Overview

The SMTP rollup feature allows you to:

1. **MX Rollups**: Group multiple MX hostnames into virtual queues
2. **Domain Macros**: Group multiple domains into virtual queues
3. **Queue Configurations**: Set SMTP connection limits and message limits per queue

This is particularly useful for managing delivery to large ISPs and email providers that use multiple MX servers.

## Components

### 1. MX Rollups

MX rollups map specific MX hostnames to virtual queue names. When Postal resolves MX records for a recipient domain and finds a matching MX hostname, it will use the associated rollup queue.

**Example:**
```
mx aspmx.l.google.com gmail-biz.rollup
mx gmr-smtp-in.l.google.com gmail-forward.rollup
```

This means any domain whose MX records point to these Google servers will be queued in the `gmail-biz.rollup` or `gmail-forward.rollup` queue.

### 2. Domain Macros

Domain macros allow you to explicitly group multiple domains into a single virtual queue. This is useful when you want to treat multiple related domains (like orange.fr and wanadoo.fr) as a single destination.

**Example:**
```
domain-macro orange orange.fr,wanadoo.fr,orange.rollup
    queue-to orange.queue
```

This groups the specified domains into the `orange.queue` virtual queue.

### 3. Queue Configurations

Queue configurations define the SMTP connection behavior for each virtual queue:

- `min-smtp-out`: Minimum concurrent SMTP connections
- `max-smtp-out`: Maximum concurrent SMTP connections
- `max-rcpt-per-message`: Maximum recipients per message

**Example:**
```
<domain orange.queue>
    min-smtp-out 1
    max-smtp-out 1
    max-rcpt-per-message 100
</domain>
```

## Installation

### 1. Run Database Migrations

```bash
cd /opt/postal
docker-compose run --rm app bundle exec rails db:migrate
```

Or if running natively:
```bash
bundle exec rails db:migrate
```

### 2. Import Configuration Files

The rollup system uses three configuration files:

- `mx_rollups.conf` - MX hostname to rollup mappings
- `domain_macros.conf` - Domain macro definitions
- `queue_configs.conf` - Queue configuration settings

Example files are provided in `config/examples/`.

#### Import All Configurations

```bash
# Copy example files to config directory
cp config/examples/mx_rollups.conf config/
cp config/examples/domain_macros.conf config/
cp config/examples/queue_configs.conf config/

# Import all configurations
bundle exec rake postal:smtp_rollup:import_all
```

#### Import Individual Configuration Types

```bash
# Import only MX rollups
bundle exec rake postal:smtp_rollup:import_mx_rollups[config/mx_rollups.conf]

# Import only domain macros
bundle exec rake postal:smtp_rollup:import_domain_macros[config/domain_macros.conf]

# Import only queue configurations
bundle exec rake postal:smtp_rollup:import_queue_configs[config/queue_configs.conf]
```

## Configuration File Formats

### MX Rollups Format

```
# Comment lines start with #
mx <mx_hostname> <rollup_name>
```

Example:
```
# Google MX servers
mx aspmx.l.google.com gmail-biz.rollup
mx alt1.aspmx.l.google.com gmail-biz.rollup
```

### Domain Macros Format

```
domain-macro <macro_name> <domain1>,<domain2>,...
    queue-to <queue_name>
```

Example:
```
domain-macro orange orange.fr,wanadoo.fr,orange.rollup
    queue-to orange.queue
```

### Queue Configurations Format

```
<domain queue_name>
    min-smtp-out <number>
    max-smtp-out <number>
    max-rcpt-per-message <number>
</domain>
```

Example:
```
<domain gmail.queue>
    min-smtp-out 2
    max-smtp-out 5
    max-rcpt-per-message 100
</domain>
```

## How It Works

### Message Flow

1. **Message Queuing**: When a message is queued, Postal checks if the recipient domain matches:
   - A domain macro (explicit domain match)
   - An MX rollup (based on MX record lookup)

2. **Virtual Queue Assignment**: If a match is found, the message is assigned to the virtual queue and tagged with the `virtual_queue` field.

3. **Batch Processing**: Messages in the same virtual queue are batched together for efficient processing.

4. **SMTP Sending**: When sending, Postal uses `SMTPSenderWithRollup` which respects the queue configuration limits:
   - Limits concurrent connections based on `max-smtp-out`
   - Respects recipient limits per message

### Priority Order

1. **Domain Macros** are checked first (explicit domain matches)
2. **MX Rollups** are checked second (based on MX record resolution)
3. If no match, the domain is processed normally

## Management Commands

### View Statistics

```bash
bundle exec rake postal:smtp_rollup:stats
```

This shows:
- Total number of MX rollups, domain macros, and queue configurations
- Breakdown of rollup groups

### Export Current Configuration

```bash
bundle exec rake postal:smtp_rollup:export
```

This exports current database configurations to `config/rollup_export/` directory.

## Use Cases

### 1. ISP-Specific Throttling

Limit concurrent connections to specific ISPs:

```
<domain orange.queue>
    min-smtp-out 1
    max-smtp-out 1
    max-rcpt-per-message 100
</domain>
```

### 2. Grouping Related Domains

Treat multiple domains as a single destination:

```
domain-macro microsoft hotmail.com,outlook.com,live.com
    queue-to microsoft.queue
```

### 3. Geographic Routing

Group MX servers by region:

```
mx eur.olc.protection.outlook.com outlook-eur.rollup
mx nam.olc.protection.outlook.com outlook-nam.rollup
mx apc.olc.protection.outlook.com outlook-apc.rollup
```

## Database Schema

### mx_rollups Table
- `mx_hostname`: The MX hostname to match
- `rollup_name`: The virtual queue name
- `enabled`: Whether this rollup is active

### domain_macros Table
- `name`: Macro name
- `domains`: Comma-separated list of domains
- `queue_name`: Virtual queue name
- `enabled`: Whether this macro is active

### queue_configurations Table
- `queue_name`: Virtual queue name
- `min_smtp_out`: Minimum concurrent connections
- `max_smtp_out`: Maximum concurrent connections
- `max_rcpt_per_message`: Max recipients per message
- `enabled`: Whether this configuration is active

### queued_messages Table (Modified)
- `virtual_queue`: The virtual queue name (new field)

## Monitoring

Monitor virtual queue performance by checking:

1. **Queue Depth**: Number of messages in each virtual queue
2. **Delivery Rates**: Success/failure rates per virtual queue
3. **Connection Usage**: Actual concurrent connections vs. configured limits

You can query the database:

```sql
-- Messages per virtual queue
SELECT virtual_queue, COUNT(*)
FROM queued_messages
WHERE virtual_queue IS NOT NULL
GROUP BY virtual_queue;

-- Queue configurations
SELECT * FROM queue_configurations WHERE enabled = 1;
```

## Troubleshooting

### Messages Not Using Rollup

1. Check if rollup is enabled:
   ```sql
   SELECT * FROM mx_rollups WHERE mx_hostname = 'your.mx.hostname';
   ```

2. Verify MX resolution:
   ```bash
   dig MX yourdomain.com
   ```

3. Check logs for rollup resolution:
   ```bash
   grep "virtual queue" /var/log/postal/postal.log
   ```

### Connection Limits Not Working

1. Verify queue configuration exists:
   ```sql
   SELECT * FROM queue_configurations WHERE queue_name = 'your.queue';
   ```

2. Check that `SMTPSenderWithRollup` is being used (check logs)

## Best Practices

1. **Start Conservative**: Begin with low `max-smtp-out` values and increase based on ISP feedback
2. **Monitor Bounces**: Watch for rate limiting or throttling responses
3. **Group Wisely**: Only group domains/MX servers that truly belong to the same destination
4. **Regular Updates**: Keep MX rollup lists updated as ISPs change infrastructure
5. **Test First**: Test with a small volume before applying to production traffic

## API Integration

The rollup system can be managed programmatically:

```ruby
# Create MX rollup
MxRollup.create!(
  mx_hostname: 'mx.example.com',
  rollup_name: 'example.rollup',
  enabled: true
)

# Create domain macro
DomainMacro.create!(
  name: 'example',
  domains: 'example.com,example.org',
  queue_name: 'example.queue',
  enabled: true
)

# Create queue configuration
QueueConfiguration.create!(
  queue_name: 'example.queue',
  min_smtp_out: 1,
  max_smtp_out: 3,
  max_rcpt_per_message: 100,
  enabled: true
)

# Resolve virtual queue for a domain
queue = SmtpRollupService.resolve_virtual_queue('example.com')
```

## Migration from PowerMTA

If you're migrating from PowerMTA:

1. Export your PowerMTA virtual-mta and domain configurations
2. Convert the format to Postal's configuration files
3. Import using the rake tasks
4. Test with a subset of traffic
5. Monitor and adjust as needed

The configuration format is intentionally similar to PowerMTA for easier migration.
