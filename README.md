# TelemetryKit for Swift

A minimal Swift client for the [Grafana Faro](https://grafana.com/oss/faro/) receiver protocol: it posts events, logs,
exceptions and measurements as JSON to a Faro-compatible endpoint, such as the `faro.receiver` component of Grafana
Alloy. There is no OpenTelemetry, no third-party dependency and no automatic instrumentation: your app decides what to
record.

This is an independent project and is not affiliated with, endorsed by or sponsored by Grafana Labs. "Grafana" and
"Faro" are used only to describe the wire format and the receiver this library talks to.

- iOS 17+ and macOS 14+, Swift 6 (strict concurrency), Foundation only (UIKit for the background task on iOS).
- Batching, retry with backoff and `Retry-After`, an offline file for what could not be sent, sessions, throttled events.
- Privacy by default: free strings are scrubbed before they are queued, a consent switch and a remote kill switch gate
  everything, and nothing is sent unless you configure an endpoint.

## Installation

Swift Package Manager, in `Package.swift`:

<!-- x-release-please-start-version -->
```swift
dependencies: [
    .package(url: "https://github.com/baby-zzz/telemetrykit-swift.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "TelemetryKit", package: "telemetrykit-swift")]),
]
```
<!-- x-release-please-end -->

In Xcode: File > Add Package Dependencies, and enter the repository URL. (Replace the URL with where the package is hosted.)

## Quick start

```swift
import TelemetryKit

// 1. Configure. Nothing is defaulted that identifies your app.
var configuration = TelemetryClient.Configuration(
    endpoint: URL(string: "https://collector.example.com/collect")!,
    app: FaroMeta.App(name: "my-app", namespace: "ios", version: "1.4.0+212", environment: "production",
                      bundleId: "com.example.myapp"),
    browser: .describing(name: "MyApp-iOS", version: "1.4.0", osName: "iOS", language: "en", mobile: true),
    eventDomain: "ios",                 // the `domain` of events
    consentKey: "telemetry_consent",    // UserDefaults keys
    debugOverrideKey: "MyTelemetry",
    sessionKey: "telemetry_session",
    release: !isDebugBuild              // your own flag: non-release builds send only when debugOverrideKey is true
)
configuration.sessionAttributes = ["platform": "ios"]   // becomes session_attr_platform in the receiver's output
configuration.consentDefault = true                      // default is false (opt-in)

// 2. Start once at launch (restores what the last run could not send).
Telemetry.start(configuration, storeURL: Telemetry.cachesFileURL("telemetry/pending.json"))

// 3. Open the remote gate when your server says so (nil = unknown yet: items wait in memory).
Telemetry.setRemoteEnabled(true)
Telemetry.setUser(accountID)            // an opaque id, nil after sign-out

// 4. Record.
Telemetry.event("stream_started", ["quality": "hd"])
Telemetry.eventThrottled("socket_disconnected", ["reason": "timeout"], interval: 60)
Telemetry.error(error, "alert")         // type, kind and scrubbed message; "alert" is where it happened
Telemetry.log(.warn, "keychain", "write failed")
Telemetry.measurement("socket_reconnect", ["reconnect_ms": 1840])

// 5. Lifecycle (e.g. from your scene delegate or ScenePhase handler).
Telemetry.applicationDidEnterBackground()   // flush within a UIKit background task, keep the rest in the file
Telemetry.applicationDidBecomeActive()
```

Names, categories and log messages are `StaticString`s on purpose: only constants say what happened; values are data and
get scrubbed. `TelemetryClient` can also be used directly (it is what the facade wraps), with an injected
`TelemetryTransport`, `UserDefaults`, clock and offline file, which is how the tests drive it.

### Gates

| Gate | Set by | Effect |
|---|---|---|
| Build | `Configuration.release`, `debugOverrideKey` in `UserDefaults` | A non-release build does not start the client unless the override is true |
| Consent | `Telemetry.setConsent(_:)`, stored under `consentKey` | Off drops everything queued and stored, and records nothing |
| Remote flag | `Telemetry.setRemoteEnabled(_:)` | `nil` = unknown: record in memory only. `false`: drop everything. `true`: send |

### Configuration

All of the tunables have defaults; the identifying fields (endpoint, app, browser, event domain, the three keys, `release`)
are required and have none. See `TelemetryClient.Configuration` for the full list: `sdk` (defaults to this library),
`sessionAttributes`, `consentDefault`, `errorKind`, `maxErrorValueLength` (500), `flushDelay` (5 s), `maxBatch` (50),
`maxPending` (500), `maxStoredBytes` (512 KiB), `maxStoredAge` (24 h), `backoff` ([5, 30, 120, 600] s),
`sessionInactivityTimeout` (15 min, no maximum length), `extraSecretParameters`, `extraScrubPatterns`.

`errorKind` turns an `Error` into a stable, low-cardinality string that is put in front of its message. The default is
`domain#code`. Replace it if your errors carry a better kind; it must not include user info.

## Privacy notes

- **Scrubbing.** Every free string (event attributes, log context, exception values and context, measurement context) is
  scrubbed before it is queued: values of secret query parameters (`token`, `access_token`, `refresh_token`, `id_token`,
  `code`, `state`, `session_state`, `key`, `password`, `secret`, `signed`, `ts`), e-mail addresses (letters-only top-level
  domain, so `sdk@1.2.3` stays), `Bearer` tokens, and `scheme://user:pass@host` credentials. Add your own with
  `extraSecretParameters` (literal names) and `extraScrubPatterns` (regular expressions, every match becomes
  `[REDACTED]`). The scrub fails closed: if a pattern does not compile, every string is replaced by `[REDACTED]`. It is a
  safety net, not a licence to put personal data in attributes. Error messages are sent (scrubbed); if yours can contain
  personal data, set `errorKind` and consider your own wrapper.
- **Consent.** Honour the user's choice: `consentDefault` is false, so a host that wants opt-out sets it to true
  deliberately. Turning consent off deletes the queue and the offline file.
- **User id.** Use an opaque, stable identifier (such as an identity provider's subject or a random UUID), never an e-mail
  address, phone number or name. Pass `nil` on sign-out. The id is sent in `meta.user.id` with every payload.
- **Offline file.** Unsent items are kept in a small JSON file (size and age capped, deleted on consent off or when the
  remote flag turns off). On iOS it is written with file protection `completeUntilFirstUserAuthentication`.
- Keep a second scrub on the server side (see below); the client's scrub is the first layer.

## Alloy `faro.receiver` example

```alloy
faro.receiver "default" {
  server {
    listen_address           = "127.0.0.1"
    listen_port              = 12347
    // Native clients send no Origin header; browsers need their origins listed
    cors_allowed_origins     = []
    max_allowed_payload_size = "1MiB"
  }

  output {
    logs   = [loki.process.faro_scrub.receiver]
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}

loki.process "faro_scrub" {
  // A second scrub on the server, e.g. e-mail addresses
  stage.replace {
    expression = "[\\w.%+-]+@[a-z0-9.-]+\\.[a-z]{2,}"
    replace    = "[email]"
  }
  forward_to = [loki.write.default.receiver]
}
```

Put an authenticating or rate-limiting reverse proxy in front of the listener if it is reachable from the internet. The
receiver turns `meta` into logfmt keys on each Loki line (`app_name`, `app_namespace`, `session_id`,
`session_attr_<key>`, `user_id`, `browser_os`, `view_name`, ...), so these are the fields to filter dashboards on.

## Wire format

`POST <endpoint>`, `Content-Type: application/json`:

```json
{
  "meta": {
    "app": { "name": "my-app", "namespace": "ios", "version": "1.4.0+212", "environment": "production", "bundleId": "com.example.myapp" },
    "sdk": { "name": "telemetrykit-swift", "version": "0.1.0" },
    "session": { "id": "k3fA9xQ2pL", "attributes": { "platform": "ios" } },
    "user": { "id": "opaque-id" },
    "view": { "name": "settings" },
    "browser": { "name": "MyApp-iOS", "version": "1.4.0", "os": "iOS 26.1", "mobile": true, "language": "en" }
  },
  "events": [{ "name": "session_start", "domain": "ios", "timestamp": "2026-11-09T04:53:20.250Z" }],
  "logs": [], "exceptions": [], "measurements": []
}
```

Empty arrays are omitted. Consecutive items with the same meta go in one request; a sign-in or a new session starts a new
one. 2xx is success; 408, 429 and 5xx are retried with backoff (and `Retry-After`); other statuses drop the batch.

## Development

```sh
swift build
swift test          # runs on macOS, no simulator needed
swiftlint           # optional, rules in .swiftlint.yml
```

## License

ISC License, copyright 2026 Baby Zzz's LLC. See [LICENSE](LICENSE).
