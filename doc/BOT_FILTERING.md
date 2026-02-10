# Bot Filtering for Email Tracking

Postal includes a bot filtering feature that helps you track real email opens and clicks by filtering out false positives from datacenter IPs (bots, email scanners, security tools, etc.).

## Overview

Many email clients, security tools, and email scanners automatically open emails and click links to check for malicious content. These automated actions create false positives in your tracking data. This feature filters out tracking events from known datacenter IP ranges from:

- **Amazon Web Services (AWS)**
- **Google Cloud Platform (GCP)**
- **Microsoft Azure**

## Configuration

Add the following configuration to your `postal.yml` file:

```yaml
version: 2

tracking:
  # Enable bot filtering for tracking (default: false)
  filter_bots: true

  # Path to store cached IP ranges (default: config/postal/datacenter_ips.json)
  ip_ranges_cache_path: /opt/postal/config/datacenter_ips.json

  # Hours to cache IP ranges before refreshing (default: 24)
  ip_ranges_cache_ttl_hours: 24
```

### Configuration Options

- **`filter_bots`**: Enable or disable bot filtering. When enabled, tracking events (opens and clicks) from datacenter IPs will be ignored.
- **`ip_ranges_cache_path`**: Location to store the cached datacenter IP ranges. The file is automatically created and updated.
- **`ip_ranges_cache_ttl_hours`**: How long to cache the IP ranges before fetching fresh data from the providers.

### Environment Variables

You can also configure these settings using environment variables:

```bash
POSTAL__TRACKING__FILTER_BOTS=true
POSTAL__TRACKING__IP_RANGES_CACHE_PATH=/opt/postal/config/datacenter_ips.json
POSTAL__TRACKING__IP_RANGES_CACHE_TTL_HOURS=24
```

## Initial Setup

After enabling bot filtering, you need to fetch the datacenter IP ranges:

```bash
bundle exec rake postal:update_datacenter_ips
```

This command will:
1. Fetch IP ranges from AWS, Google, and Azure
2. Parse and combine all ranges
3. Save them to the cache file specified in your configuration

The output will show:
```
Fetching datacenter IP ranges from AWS, Google, and Azure...
Successfully fetched and cached IP ranges:
  - IPv4 ranges: 15234
  - IPv6 ranges: 3421
  - Cache location: /opt/postal/config/datacenter_ips.json
```

## How It Works

1. **IP Range Fetching**: The system fetches IP ranges from official sources:
   - AWS: `https://ip-ranges.amazonaws.com/ip-ranges.json`
   - Google: `https://www.gstatic.com/ipranges/goog.json`
   - Azure: Microsoft's ServiceTags JSON (updated periodically)

2. **Caching**: IP ranges are cached locally to avoid repeated API calls. The cache is automatically refreshed based on the TTL setting.

3. **Request Filtering**: When a tracking request (email open or link click) comes in:
   - The request IP is checked against the cached datacenter IP ranges
   - If the IP matches a datacenter range, the tracking event is **not recorded**
   - The email image still loads and links still redirect normally
   - Only the tracking/logging is skipped

4. **In-Memory Optimization**: IP ranges are loaded into memory and refreshed hourly to ensure fast lookups without impacting performance.

## Maintenance

### Automatic Updates

The IP ranges cache is automatically refreshed based on the `ip_ranges_cache_ttl_hours` setting. When the cache expires, fresh data is fetched on the next tracking request.

### Manual Updates

You can manually update the IP ranges at any time:

```bash
bundle exec rake postal:update_datacenter_ips
```

### Scheduled Updates

For production environments, consider setting up a cron job to update the IP ranges regularly:

```bash
# Update datacenter IPs daily at 3 AM
0 3 * * * cd /opt/postal && bundle exec rake postal:update_datacenter_ips
```

## Impact on Tracking

### What Gets Filtered

When bot filtering is enabled, the following will **NOT** be tracked if they originate from datacenter IPs:

- Email opens (tracking pixel loads)
- Link clicks
- Associated webhooks for these events

### What Still Works

- Emails still display correctly (images load)
- Links still redirect properly
- Tracking from real users (non-datacenter IPs) works normally

### Example Scenario

**Without Bot Filtering:**
- Email sent: 1000
- Opens tracked: 850 (includes 300 bot opens)
- Clicks tracked: 200 (includes 50 bot clicks)

**With Bot Filtering:**
- Email sent: 1000
- Opens tracked: 550 (real users only)
- Clicks tracked: 150 (real users only)

## Data Sources

The bot filtering system uses official IP range data from:

1. **AWS IP Ranges**
   - Source: Amazon Web Services
   - URL: https://ip-ranges.amazonaws.com/ip-ranges.json
   - Updated: Automatically by AWS when ranges change

2. **Google Cloud IP Ranges**
   - Source: Google Cloud Platform
   - URL: https://www.gstatic.com/ipranges/goog.json
   - Updated: Automatically by Google when ranges change

3. **Azure IP Ranges**
   - Source: Microsoft Azure
   - URL: Microsoft Download Center (ServiceTags JSON)
   - Updated: Weekly by Microsoft
   - Note: Azure publishes new files regularly with dated filenames

## Troubleshooting

### Cache File Not Created

If the cache file isn't created:
1. Check that the directory exists and is writable
2. Run the update task manually: `bundle exec rake postal:update_datacenter_ips`
3. Check the logs for any error messages

### Too Many/Few Events Filtered

If you notice unexpected filtering behavior:
1. Check that `filter_bots` is set correctly
2. Verify the cache file exists and is recent
3. Update the IP ranges: `bundle exec rake postal:update_datacenter_ips`
4. Check the logs for any IP checking errors

### Performance Concerns

The bot filtering system is optimized for performance:
- IP ranges are cached in memory
- IP lookups use efficient CIDR matching
- Cache is refreshed in background on expiry
- No impact on email delivery or link redirection

## Limitations

- Only filters datacenter IPs from AWS, Google, and Azure
- Does not filter other cloud providers or hosting services
- Does not filter based on user agent strings
- Requires periodic updates to maintain accuracy

## Future Enhancements

Potential improvements for future versions:
- Additional cloud provider support (DigitalOcean, Linode, etc.)
- User agent-based filtering
- Custom IP range configuration
- Per-server bot filtering settings
- Detailed filtering statistics and reports
