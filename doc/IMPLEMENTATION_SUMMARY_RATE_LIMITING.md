# Implementation Summary: Rate Limiting, Queue Backoff Mode, and Global Backoff Rules

## Overview
This summary reflects the current behavior for queue controls:

- `max-msg-rate` defers in queue when exceeded (no reroute fallback)
- queues have explicit `mode` (`normal`/`backoff`)
- `backoff-reroute-to` is used only while a queue is in `backoff`
- global `<smtp-pattern-list>` rules can switch queue mode or trigger `bounce-rcpt`

## Current Implementation

### Database

- `queue_configurations` includes:
  - `max_msg_rate`
  - `backoff_reroute_to`
  - `mode`
  - `backoff_base_delay_seconds`
  - `backoff_auto_success_threshold`
  - `backoff_auto_success_window_seconds`
  - `backoff_success_count`
  - `backoff_started_at`
  - `backoff_last_success_at`
- `backoff_rules` table includes:
  - `pattern`
  - `action` (`mode=backoff` or `bounce-rcpt`)
  - `enabled`

### Model Behavior

`QueueConfiguration` now provides:

- mode helpers: `normal?`, `backoff?`, `enter_backoff!`, `exit_backoff!`
- auto-return tracking: `register_backoff_success!`, `register_backoff_failure!`
- backoff pacing: `effective_backoff_base_delay` (minimum default 2h)
- rate-limit defer helper: `rate_limit_retry_seconds`
- relay gating: `backoff_relay_server` returns value only in backoff mode

`BackoffRule` now provides:

- config import from `<smtp-pattern-list ...>` syntax
- response matching utilities
- support for `mode=backoff` and `bounce-rcpt`

### Sender/Dequeuer Behavior

- `SMTPSenderWithRollup`:
  - when `max-msg-rate` is exceeded, returns SoftFail with retry so message stays queued
  - does not reroute on rate-limit threshold
  - only uses `backoff-reroute-to` if queue mode is `backoff`
- `OutgoingMessageProcessor`:
  - applies global backoff rules to SMTP responses
  - `mode=backoff` switches queue into backoff mode and increases retry spacing
  - `bounce-rcpt` forces permanent failure for the recipient/message
  - tracks success/failure to support optional auto-return to normal mode

## Config Import/Export and Commands

- Import tasks:
  - `postal:smtp_rollup:import_queue_configs`
  - `postal:smtp_rollup:import_backoff_rules`
  - `postal:smtp_rollup:import_all` (includes backoff rules)
- Queue mode operations:
  - `postal:smtp_rollup:set_queue_mode[queue_name,normal|backoff]`
  - `postal:smtp_rollup:queue_mode[queue_name]`
- Export includes `backoff_rules.conf`

## Documentation and Examples Updated

- `doc/RATE_LIMITING_AND_BACKOFF.md`
- `doc/smtp_rollup_guide.md`
- `SMTP_ROLLUP_README.md`
- `config/examples/queue_configs.conf`
- `config/examples/backoff_rules.conf`
- `doc/config/queue_configs.conf`
- `doc/config/backoff_rules.conf`

## PowerMTA Compatibility Notes

- Queue and rule syntax remains PowerMTA-style (`max-msg-rate`, `backoff-reroute-to`, `<smtp-pattern-list>`, `reply /.../ mode=backoff`, `bounce-rcpt`).
- Behavior is adapted to Postal internals: queue deferral/retry + explicit queue mode transitions.
