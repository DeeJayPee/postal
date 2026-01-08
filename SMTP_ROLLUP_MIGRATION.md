# SMTP Rollup Migration Guide

This guide helps you migrate to the SMTP rollup feature in Postal.

## Pre-Migration Checklist

- [ ] Backup your Postal database
- [ ] Review current email delivery patterns
- [ ] Identify domains/ISPs that need throttling
- [ ] Plan your virtual queue structure
- [ ] Schedule migration during low-traffic period

## Step-by-Step Migration

### Step 1: Backup Database

```bash
# For Docker installations
docker-compose exec mysql mysqldump -u postal -p postal > postal_backup_$(date +%Y%m%d).sql

# For native installations
mysqldump -u postal -p postal > postal_backup_$(date +%Y%m%d).sql
```

### Step 2: Run Database Migrations

```bash
# For Docker installations
docker-compose run --rm app bundle exec rails db:migrate

# For native installations
cd /opt/postal
bundle exec rails db:migrate
```

Expected output:
```
== 20241121000001 CreateMXRollups: migrating ==================================
-- create_table(:mx_rollups)
== 20241121000001 CreateMXRollups: migrated (0.0234s) ========================

== 20241121000002 CreateDomainMacros: migrating ===============================
-- create_table(:domain_macros)
== 20241121000002 CreateDomainMacros: migrated (0.0189s) ======================

== 20241121000003 CreateQueueConfigurations: migrating ========================
-- create_table(:queue_configurations)
== 20241121000003 CreateQueueConfigurations: migrated (0.0201s) ===============

== 20241121000004 AddVirtualQueueToQueuedMessages: migrating ==================
-- add_column(:queued_messages, :virtual_queue, :string)
-- add_index(:queued_messages, :virtual_queue)
== 20241121000004 AddVirtualQueueToQueuedMessages: migrated (0.0156s) =========
```

### Step 3: Verify Migration

```bash
# Check that new tables exist
bundle exec rails runner "puts MXRollup.table_exists?"
bundle exec rails runner "puts DomainMacro.table_exists?"
bundle exec rails runner "puts QueueConfiguration.table_exists?"
```

All should return `true`.

### Step 4: Prepare Configuration Files

#### Option A: Use Provided Examples

```bash
cp config/examples/mx_rollups.conf config/
cp config/examples/domain_macros.conf config/
cp config/examples/queue_configs.conf config/
```

#### Option B: Create Custom Configuration

Create your own configuration files based on your needs:

**config/mx_rollups.conf:**
```
# Your custom MX rollups
mx mx1.your-isp.com your-isp.rollup
mx mx2.your-isp.com your-isp.rollup
```

**config/domain_macros.conf:**
```
# Your custom domain macros
domain-macro your-macro domain1.com,domain2.com
    queue-to your.queue
```

**config/queue_configs.conf:**
```
# Your custom queue configurations
<domain your.queue>
    min-smtp-out 1
    max-smtp-out 2
    max-rcpt-per-message 100
</domain>
```

### Step 5: Import Configurations

```bash
# Import all configurations
bundle exec rake postal:smtp_rollup:import_all
```

Or import individually:
```bash
bundle exec rake postal:smtp_rollup:import_mx_rollups
bundle exec rake postal:smtp_rollup:import_domain_macros
bundle exec rake postal:smtp_rollup:import_queue_configs
```

### Step 6: Verify Import

```bash
bundle exec rake postal:smtp_rollup:stats
```

Expected output:
```
=== SMTP Rollup Statistics ===

MX Rollups: 42
Domain Macros: 5
Queue Configurations: 8

=== Rollup Groups ===
  gmail-biz.rollup: 2 MX record(s)
  yahoo.rollup: 3 MX record(s)
  orange.rollup: 1 MX record(s)
  ...
```

### Step 7: Test with Low Volume

Start with a small subset of traffic:

1. **Create a test queue configuration:**
```sql
INSERT INTO queue_configurations (queue_name, min_smtp_out, max_smtp_out, max_rcpt_per_message, enabled)
VALUES ('test.queue', 1, 1, 100, 1);
```

2. **Create a test domain macro:**
```sql
INSERT INTO domain_macros (name, domains, queue_name, enabled)
VALUES ('test', 'test-domain.com', 'test.queue', 1);
```

3. **Send test emails to test-domain.com**

4. **Monitor logs:**
```bash
tail -f /var/log/postal/postal.log | grep "virtual queue"
```

Expected log entries:
```
Using virtual queue 'test.queue' for domain test-domain.com
Sending via virtual queue: test.queue
```

### Step 8: Monitor Initial Performance

Check queue depth:
```sql
SELECT virtual_queue, COUNT(*) as count
FROM queued_messages
WHERE virtual_queue IS NOT NULL
GROUP BY virtual_queue;
```

Check delivery status:
```sql
SELECT m.status, qm.virtual_queue, COUNT(*) as count
FROM queued_messages qm
JOIN messages m ON m.id = qm.message_id
WHERE qm.virtual_queue IS NOT NULL
GROUP BY m.status, qm.virtual_queue;
```

### Step 9: Gradual Rollout

1. **Week 1**: Enable for 1-2 major ISPs
2. **Week 2**: Add more ISPs if Week 1 is successful
3. **Week 3**: Enable for all configured rollups
4. **Week 4**: Fine-tune connection limits based on data

### Step 10: Restart Services

```bash
# For Docker installations
docker-compose restart app

# For native installations
systemctl restart postal
```

## Rollback Procedure

If you need to rollback:

### Option 1: Disable Rollups (Soft Rollback)

```sql
-- Disable all rollups without removing data
UPDATE mx_rollups SET enabled = 0;
UPDATE domain_macros SET enabled = 0;
UPDATE queue_configurations SET enabled = 0;
```

### Option 2: Full Rollback

```bash
# Restore database backup
mysql -u postal -p postal < postal_backup_YYYYMMDD.sql

# Rollback migrations
bundle exec rails db:rollback STEP=4
```

## Common Migration Issues

### Issue 1: MX Rollups Not Matching

**Symptom:** Messages not using virtual queues

**Solution:**
```bash
# Verify MX records
dig MX yourdomain.com

# Check if MX hostname is in rollup table
bundle exec rails runner "puts MXRollup.where(mx_hostname: 'your.mx.hostname').inspect"
```

### Issue 2: Connection Limits Not Applied

**Symptom:** More connections than configured max

**Solution:**
```bash
# Verify queue configuration
bundle exec rails runner "puts QueueConfiguration.find_by(queue_name: 'your.queue').inspect"

# Check that virtual_queue field is set
bundle exec rails runner "puts QueuedMessage.where.not(virtual_queue: nil).count"
```

### Issue 3: Performance Degradation

**Symptom:** Slower message processing

**Solution:**
1. Check if MX lookups are timing out
2. Increase DNS cache TTL
3. Verify database indexes are created
4. Consider increasing `max_smtp_out` for high-volume queues

## Post-Migration Monitoring

### Daily Checks (First Week)

```bash
# Check queue statistics
bundle exec rake postal:smtp_rollup:stats

# Check for errors in logs
grep -i "error.*rollup" /var/log/postal/postal.log

# Check queue depth
bundle exec rails runner "puts QueuedMessage.where.not(virtual_queue: nil).group(:virtual_queue).count"
```

### Weekly Checks (First Month)

1. Review delivery rates per virtual queue
2. Adjust connection limits based on performance
3. Add new rollups for additional ISPs
4. Fine-tune domain macros

### Metrics to Track

- **Queue Depth**: Messages waiting per virtual queue
- **Delivery Rate**: Success rate per virtual queue
- **Connection Usage**: Actual vs. configured connections
- **Bounce Rate**: Bounces per virtual queue
- **Processing Time**: Time to process messages per queue

## Optimization Tips

### 1. Tune Connection Limits

Start conservative and increase:
```sql
-- Start with
UPDATE queue_configurations SET max_smtp_out = 1 WHERE queue_name = 'new.queue';

-- After monitoring, increase if needed
UPDATE queue_configurations SET max_smtp_out = 3 WHERE queue_name = 'new.queue';
```

### 2. Group Related Domains

Combine domains that share infrastructure:
```sql
INSERT INTO domain_macros (name, domains, queue_name, enabled)
VALUES ('google', 'gmail.com,googlemail.com,gmail-biz.rollup', 'google.queue', 1);
```

### 3. Use Descriptive Queue Names

Good: `orange-fr.queue`, `gmail-business.queue`
Bad: `queue1`, `q2`

### 4. Regular Maintenance

```bash
# Weekly: Export current configuration
bundle exec rake postal:smtp_rollup:export

# Monthly: Review and update MX rollups
# ISPs change infrastructure, keep rollups current
```

## Migration Timeline Example

### Day 1: Preparation
- Backup database
- Review documentation
- Plan queue structure

### Day 2: Migration
- Run migrations
- Import configurations
- Test with low volume

### Day 3-7: Initial Rollout
- Enable for 1-2 major ISPs
- Monitor closely
- Adjust as needed

### Week 2-4: Full Rollout
- Gradually enable all rollups
- Fine-tune connection limits
- Document learnings

### Month 2+: Optimization
- Regular monitoring
- Periodic adjustments
- Add new rollups as needed

## Success Criteria

Migration is successful when:

- [ ] All migrations completed without errors
- [ ] Configuration imported successfully
- [ ] Test messages use virtual queues
- [ ] Delivery rates remain stable or improve
- [ ] No increase in bounce rates
- [ ] Connection limits are respected
- [ ] Logs show rollup usage
- [ ] Queue depth is manageable

## Getting Help

If you encounter issues:

1. Check logs: `/var/log/postal/postal.log`
2. Review documentation: `doc/smtp_rollup_guide.md`
3. Verify database records
4. Check configuration files
5. Test with simple configuration first

## Best Practices Summary

1. **Always backup before migration**
2. **Test with low volume first**
3. **Monitor closely during rollout**
4. **Start with conservative limits**
5. **Document your configuration**
6. **Keep rollups updated**
7. **Regular performance reviews**
8. **Have a rollback plan ready**

## Conclusion

The SMTP rollup feature provides powerful queue management capabilities. Take your time with migration, monitor closely, and adjust based on your specific needs. The gradual rollout approach minimizes risk while allowing you to learn and optimize.
