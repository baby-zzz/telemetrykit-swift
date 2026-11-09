# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-11-09

### Added
- a session starts when the app becomes active, not only with the first recorded item

## [0.2.0] - 2026-11-09

### Added
- configurable scrubbing (policy per field, presets, per-call override)

### Fixed
- never scrub the library's own category key
- exempt where and category only in the maps the library fills
- the library's log category wins over a caller's category key

## [0.1.0] - 2026-11-09

First release, extracted from the Baby Zzz iOS app.

### Added
- `TelemetryClient`: a queue that batches items (by size and delay), groups them by meta, retries failures with backoff
  and `Retry-After`, keeps unsent items in an offline file, and joins concurrent flushes into one drain.
- `Telemetry` facade for events, throttled events, handled errors, warn/error logs and measurements, with the
  release/debug "build allows" gate, the user's consent and a tri-state remote flag (unknown holds in memory, disabled
  drops, enabled sends).
- `TelemetryScrub`: secret query parameters, e-mail addresses, bearer tokens and `scheme://user:pass@` credentials, failing
  closed; extra parameter names and regular expressions through the configuration.
- `TelemetrySession`: a session that lasts until a configurable inactivity timeout, with no maximum length.
- `TelemetryTransport` protocol and `URLSessionTelemetryTransport` (ephemeral session).
- Faro payload types (`FaroPayload`, `FaroMeta`, events, logs, exceptions, measurements).
- A UIKit background task for flushing when the app leaves the foreground (iOS only).
- Platforms: iOS 17, macOS 14; Swift 6 language mode.
