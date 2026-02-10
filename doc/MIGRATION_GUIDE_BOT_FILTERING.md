# Migration Guide: Enabling Bot Filtering

This guide helps you enable bot filtering on an existing Postal installation.

## Prerequisites

- Postal installation running
- Access to configuration files
- Ability to run rake tasks
- (Optional) Cron access for scheduled updates

---

## Step-by-Step Migration

### Step 1: Update Configuration

Edit your `config/postal/postal.yml` file:

```yaml
tracking:
  filter_bots: true
```

**Optional**: Customize cache location and TTL:

```yaml
tracking:
  filter_bots: true
  ip_ranges_cache_path: /opt/postal/config/datacenter_ips.json
  ip_ranges_cache_ttl_hours: 24
```

### Step 2: Fetch Datacenter IP Ranges

Run the update task to download and cache IP ranges:

```bash
cd /opt/postal
bundle exec rake postal:update_datacenter_ips
```

**Expected Output**:
```
Fetching datacenter IP ranges from AWS, Google, and Azure...
Successfully fetched and cached IP ranges:
  - IPv4 ranges: 15234
  - IPv6 ranges: 3421
  - Cache location: /opt/postal/config/datacenter_ips.json
```

**Troubleshooting**:
- If the command fails, check internet connectivity
- Ensure the cache directory is writable
- Check logs: `tail -f log/production.log`

### Step 3: Verify Cache File

Check that the cache file was created:

```bash
ls -lh /opt/postal/config/datacenter_ips.json
```

**Expected**: File should exist and be ~5-10MB

View cache contents:
```bash
cat /opt/postal/config/datacenter_ips.json | jq '.ipv4 | length'
cat /opt/postal/config/datacenter_ips.json | jq '.ipv6 | length'
```

### Step 4: Restart Postal Services

Restart all Postal services to load the new configuration:

```bash
# Using systemd
sudo systemctl restart postal-web
sudo systemctl restart postal-worker

# Or using your process manager
# supervisorctl restart postal:*
# pm2 restart postal
```

### Step 5: Verify It's Working

#### Check Logs
```bash
tail -f log/production.log
```

Send a test email and look for any bot-related log entries.

#### Test Tracking
1. Send a test email through Postal
2. Open it from a regular IP (should track)
3. Check your tracking dashboard

#### Verify Configuration
```bash
bundle exec rails console
> Postal::Config.tracking.filter_bots?
=> true
```

### Step 6: Schedule Automatic Updates (Recommended)

Add a cron job to update IP ranges daily:

```bash
crontab -e
```

Add this line:
```bash
0 3 * * * cd /opt/postal && bundle exec rake postal:update_datacenter_ips >> /var/log/postal/ip_update.log 2>&1
```

This runs daily at 3 AM and logs output.

---

## Verification Checklist

- [ ] Configuration file updated with `filter_bots: true`
- [ ] IP ranges fetched successfully
- [ ] Cache file exists and contains data
- [ ] Services restarted
- [ ] Logs show no errors
- [ ] Tracking still works for real users
- [ ] Cron job scheduled (optional)

---

## Rollback Plan

If you need to disable bot filtering:

### Quick Disable (No Restart Required)

Edit `config/postal/postal.yml`:
```yaml
tracking:
  filter_bots: false
```

Restart services:
```bash
sudo systemctl restart postal-web postal-worker
```

### Complete Removal

1. Disable in configuration (as above)
2. Remove cache file:
   ```bash
   rm /opt/postal/config/datacenter_ips.json
   ```
3. Remove cron job:
   ```bash
   crontab -e
   # Remove the ip_update line
   ```

---

## Expected Impact

### Before Bot Filtering

**Typical tracking numbers**:
- 1000 emails sent
- 850 opens tracked (includes ~300 bot opens)
- 200 clicks tracked (includes ~50 bot clicks)
- Open rate: 85%
- Click rate: 20%

### After Bot Filtering

**More accurate numbers**:
- 1000 emails sent
- 550 opens tracked (real users only)
- 150 clicks tracked (real users only)
- Open rate: 55% (more accurate)
- Click rate: 15% (more accurate)

### What Changes

**Will NOT be tracked**:
- Opens from AWS, Google, Azure IPs
- Clicks from datacenter IPs
- Email security scanners
- Link preview generators

**Will still be tracked**:
- Real user opens
- Real user clicks
- Opens from residential IPs
- Opens from corporate networks (non-datacenter)

**Still works normally**:
- Email delivery
- Image loading
- Link redirection
- Webhooks (for real users)

---

## Monitoring After Migration

### Week 1: Close Monitoring

**Daily checks**:
```bash
# Check cache is fresh
ls -lh /opt/postal/config/datacenter_ips.json

# Monitor logs for errors
tail -100 log/production.log | grep -i "bot\|datacenter"

# Verify tracking still works
# Send test emails and check dashboard
```

### Week 2-4: Regular Monitoring

**Weekly checks**:
- Compare tracking metrics before/after
- Check for any unusual patterns
- Verify cache updates are working
- Review error logs

### Ongoing: Automated Monitoring

**Set up alerts for**:
- Cache file age > 48 hours
- Failed IP range fetches
- Sudden drop in tracking volume
- Error rate increases

---

## Common Issues & Solutions

### Issue 1: Cache File Not Created

**Symptoms**: No datacenter_ips.json file after running update task

**Solutions**:
```bash
# Check directory exists
mkdir -p /opt/postal/config/

# Check permissions
chmod 755 /opt/postal/config/
chown postal:postal /opt/postal/config/

# Run update again
bundle exec rake postal:update_datacenter_ips
```

### Issue 2: "Failed to fetch" Errors

**Symptoms**: Errors when fetching from AWS/Google/Azure

**Solutions**:
```bash
# Check internet connectivity
curl -I https://ip-ranges.amazonaws.com/ip-ranges.json

# Check firewall rules
# Ensure outbound HTTPS is allowed

# Check DNS resolution
nslookup ip-ranges.amazonaws.com

# Try manual fetch
curl https://ip-ranges.amazonaws.com/ip-ranges.json | jq . | head
```

### Issue 3: No Tracking Events

**Symptoms**: No opens or clicks being tracked at all

**Solutions**:
```bash
# Verify filter_bots is not too aggressive
bundle exec rails console
> Postal::Config.tracking.filter_bots?
=> true

# Check if cache is valid
cat /opt/postal/config/datacenter_ips.json | jq .

# Temporarily disable to test
# Edit config: filter_bots: false
# Restart services
# Test tracking
```

### Issue 4: Too Many Events Filtered

**Symptoms**: Legitimate tracking events being filtered

**Solutions**:
1. Check if users are on VPNs (may route through datacenters)
2. Verify cache is not corrupted
3. Update IP ranges: `bundle exec rake postal:update_datacenter_ips`
4. Check logs for specific IPs being filtered
5. Consider if your user base is primarily datacenter-based (rare)

### Issue 5: Cache Never Updates

**Symptoms**: Cache file timestamp is old

**Solutions**:
```bash
# Check cron job is running
crontab -l | grep ip_update

# Check cron logs
tail -f /var/log/postal/ip_update.log

# Run manually to test
bundle exec rake postal:update_datacenter_ips

# Verify TTL setting
bundle exec rails console
> Postal::Config.tracking.ip_ranges_cache_ttl_hours
=> 24
```

---

## Performance Considerations

### Expected Resource Usage

**Memory**:
- IP ranges: ~50MB
- Negligible increase in overall memory

**CPU**:
- IP checking: < 1ms per request
- No noticeable CPU increase

**Disk**:
- Cache file: ~5-10MB
- Logs: Minimal increase

**Network**:
- Initial fetch: ~5-10MB download
- Daily updates: ~5-10MB download

### Optimization Tips

1. **Cache Location**: Use fast storage (SSD) for cache file
2. **TTL**: Increase to 48 hours if updates aren't critical
3. **Cron Timing**: Schedule during low-traffic hours
4. **Monitoring**: Use existing monitoring tools

---

## Testing Checklist

### Pre-Migration Testing

- [ ] Backup current configuration
- [ ] Document current tracking metrics
- [ ] Test in staging environment first
- [ ] Verify internet connectivity
- [ ] Check disk space for cache file

### Post-Migration Testing

- [ ] Send test email to yourself
- [ ] Verify email opens are tracked
- [ ] Verify link clicks are tracked
- [ ] Check webhooks are triggered
- [ ] Review logs for errors
- [ ] Compare metrics before/after

### Load Testing (Optional)

```bash
# Send 100 test emails
for i in {1..100}; do
  # Send email via API
done

# Monitor performance
top -p $(pgrep -f postal)
```

---

## Support & Resources

### Documentation
- Quick Start: `BOT_FILTERING_README.md`
- Full Documentation: `doc/BOT_FILTERING.md`
- Implementation Details: `IMPLEMENTATION_SUMMARY.md`
- All Changes: `CHANGES_SUMMARY.md`

### Commands Reference
```bash
# Update IP ranges
bundle exec rake postal:update_datacenter_ips

# Check configuration
bundle exec rails console
> Postal::Config.tracking.filter_bots?
> Postal::Config.tracking.ip_ranges_cache_path

# View cache
cat /opt/postal/config/datacenter_ips.json | jq .

# Monitor logs
tail -f log/production.log | grep -i bot

# Test IP checking
bundle exec rails console
> Postal::BotIPChecker.bot_ip?("52.94.76.1")
=> true
> Postal::BotIPChecker.bot_ip?("1.2.3.4")
=> false
```

### Getting Help

If you encounter issues:

1. **Check logs**: `tail -f log/production.log`
2. **Verify configuration**: `bundle exec rails console`
3. **Test manually**: Run rake task with verbose output
4. **Review documentation**: See files listed above
5. **Check GitHub issues**: Search for similar problems

---

## Success Criteria

Your migration is successful when:

✅ Configuration is enabled
✅ Cache file exists and is fresh
✅ Services are running without errors
✅ Real user tracking still works
✅ Bot traffic is being filtered
✅ Metrics show expected reduction
✅ Automatic updates are scheduled

---

## Timeline

**Estimated migration time**: 15-30 minutes

- Configuration: 5 minutes
- IP fetch: 2-5 minutes
- Service restart: 2-5 minutes
- Verification: 5-10 minutes
- Cron setup: 5 minutes

**Downtime**: None (services restart briefly)

---

## Post-Migration

### First Week

Monitor closely:
- Check logs daily
- Verify tracking works
- Compare metrics
- Watch for errors

### First Month

Regular checks:
- Weekly metric reviews
- Cache update verification
- Error rate monitoring
- User feedback

### Ongoing

Maintenance:
- Monthly metric analysis
- Quarterly documentation review
- Annual provider list update
- Continuous monitoring

---

## Conclusion

Bot filtering is now enabled! Your tracking data will be more accurate, showing only real user engagement.

**Remember**:
- Metrics will decrease (this is expected and good)
- Real user tracking continues normally
- Email delivery is unaffected
- Links and images still work for everyone

**Next steps**:
1. Monitor for 1-2 weeks
2. Analyze new metrics
3. Adjust marketing strategies based on accurate data
4. Share results with your team

Enjoy more accurate email tracking! 🎉
