# Bot Filtering for Email Tracking - Quick Start

This feature helps you track **real email opens and clicks** by filtering out false positives from datacenter IPs (email scanners, security tools, bots).

## Quick Setup

### 1. Enable Bot Filtering

Add to your `config/postal/postal.yml`:

```yaml
tracking:
  filter_bots: true
```

### 2. Fetch Datacenter IP Ranges

```bash
bundle exec rake postal:update_datacenter_ips
```

### 3. Restart Postal

```bash
# Restart your Postal services
systemctl restart postal-web
systemctl restart postal-worker
```

## What Gets Filtered

The system filters tracking events from:
- ✅ Amazon Web Services (AWS)
- ✅ Google Cloud Platform (GCP)
- ✅ Microsoft Azure

## How It Works

- **Email opens** and **link clicks** from datacenter IPs are **not tracked**
- Emails still display correctly and links still work
- Only the tracking/logging is skipped for bot traffic
- Real user tracking continues normally

## Maintenance

### Automatic Updates
IP ranges are cached and auto-refreshed every 24 hours (configurable).

### Manual Updates
```bash
bundle exec rake postal:update_datacenter_ips
```

### Scheduled Updates (Recommended)
Add to crontab for daily updates:
```bash
0 3 * * * cd /opt/postal && bundle exec rake postal:update_datacenter_ips
```

## Configuration Options

```yaml
tracking:
  # Enable/disable bot filtering (default: false)
  filter_bots: true

  # Cache file location (default: config/postal/datacenter_ips.json)
  ip_ranges_cache_path: /opt/postal/config/datacenter_ips.json

  # Cache TTL in hours (default: 24)
  ip_ranges_cache_ttl_hours: 24
```

## Environment Variables

```bash
POSTAL__TRACKING__FILTER_BOTS=true
POSTAL__TRACKING__IP_RANGES_CACHE_PATH=/opt/postal/config/datacenter_ips.json
POSTAL__TRACKING__IP_RANGES_CACHE_TTL_HOURS=24
```

## Expected Results

**Before Bot Filtering:**
- Opens: 850 (includes ~300 bot opens)
- Clicks: 200 (includes ~50 bot clicks)

**After Bot Filtering:**
- Opens: 550 (real users only)
- Clicks: 150 (real users only)

## Troubleshooting

**Cache file not created?**
```bash
# Check directory permissions
ls -la config/postal/

# Run update manually
bundle exec rake postal:update_datacenter_ips

# Check logs
tail -f log/production.log
```

**Need to verify it's working?**
```bash
# Check cache file exists and is recent
ls -lh config/postal/datacenter_ips.json

# View cache contents
cat config/postal/datacenter_ips.json | jq '.ipv4 | length'
```

## Full Documentation

See [doc/BOT_FILTERING.md](doc/BOT_FILTERING.md) for complete documentation.

## Data Sources

- **AWS**: https://ip-ranges.amazonaws.com/ip-ranges.json
- **Google**: https://www.gstatic.com/ipranges/goog.json
- **Azure**: Microsoft ServiceTags JSON (updated weekly)

All sources are official and maintained by the respective cloud providers.
