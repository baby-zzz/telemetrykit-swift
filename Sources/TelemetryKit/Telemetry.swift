import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// The facade: one process-wide client. Every call is a cheap enqueue and a no-op until `start` ran, in a non-release
/// build (unless `Configuration.debugOverrideKey` is true in the defaults), when the user's consent is off, or while the
/// host's remote flag says no. Only constants (`StaticString`) name what happened; free values pass through
/// `TelemetryScrub`; the user is an opaque id, never an e-mail address or a name.
public enum Telemetry {
    private struct DefaultsBox: @unchecked Sendable {
        let value: UserDefaults
    }

    private struct Installed: Sendable {
        var configuration: TelemetryClient.Configuration?
        var defaults: DefaultsBox?
        var client: TelemetryClient?
    }

    private static let current = OSAllocatedUnfairLock<Installed>(initialState: Installed())

    /// The running client; nil before `start`, or when the build may not send
    public static var client: TelemetryClient? { current.withLock { $0.client } }

    // MARK: - Set-up

    /// Whether this build may send at all: release builds, or a non-release build whose `debugOverrideKey` is true
    public static func buildAllows(_ configuration: TelemetryClient.Configuration, defaults: UserDefaults = .standard) -> Bool {
        configuration.release || defaults.bool(forKey: configuration.debugOverrideKey)
    }

    /// The user's consent: `consentKey`, or `consentDefault` when it was never set
    public static func consent(_ configuration: TelemetryClient.Configuration, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: configuration.consentKey) as? Bool ?? configuration.consentDefault
    }

    /// At launch, before anything is recorded; restores what the last run could not send. `storeURL` is the offline
    /// file (nil: nothing is kept across launches), see `cachesFileURL(_:)`.
    public static func start(_ configuration: TelemetryClient.Configuration, defaults: UserDefaults = .standard, storeURL: URL? = nil,
                             transport: any TelemetryTransport = URLSessionTelemetryTransport()) {
        let box = DefaultsBox(value: defaults)
        current.withLock { $0.configuration = configuration; $0.defaults = box }
        guard buildAllows(configuration, defaults: defaults) else { return }
        install(TelemetryClient(configuration: configuration, transport: transport, defaults: defaults, storeURL: storeURL,
                                consent: consent(configuration, defaults: defaults)))
    }

    /// A file in the user's caches directory, e.g. `cachesFileURL("telemetry/pending.json")`
    public static func cachesFileURL(_ relativePath: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: relativePath)
    }

    /// Replaces the client (tests; nil stops telemetry)
    public static func install(_ client: TelemetryClient?) {
        current.withLock {
            $0.client = client
            if let client { $0.configuration = client.configuration }
        }
        client?.restore()
    }

    // MARK: - Gates and identity

    /// The user's setting; off drops everything queued at once. No-op before `start`.
    public static func setConsent(_ on: Bool) {
        let (configuration, box, client) = current.withLock { ($0.configuration, $0.defaults, $0.client) }
        if let configuration { (box?.value ?? .standard).set(on, forKey: configuration.consentKey) }
        client?.setConsent(on)
    }

    /// The host's remote flag; nil = no answer yet (items wait in memory), false drops, true sends
    public static func setRemoteEnabled(_ enabled: Bool?) {
        client?.setRemote(enabled.map { $0 ? .enabled : .disabled } ?? .unknown)
    }

    /// After a sign-in or a restored session; nil after a sign-out
    public static func setUser(_ id: String?) {
        client?.setUser(id)
    }

    /// The current screen, or nil
    public static func setView(_ name: String?) {
        client?.setView(name)
    }

    // MARK: - Signals

    /// A named event; attribute values are low-cardinality strings
    public static func event(_ name: StaticString, _ attributes: [String: String] = [:], scrub: Bool? = nil) {
        guard let client else { return }
        client.record(.event(FaroEvent(name: "\(name)", domain: client.configuration.eventDomain, timestamp: timestamp(),
                                       attributes: attributes.isEmpty ? nil : attributes)), scrub: scrub)
    }

    /// At most once per `interval` per `key` (default: the name), with `suppressed`: how many were dropped since
    public static func eventThrottled(_ name: StaticString, _ attributes: [String: String] = [:], key: String? = nil, interval: TimeInterval = 60,
                                       scrub: Bool? = nil) {
        guard let client else { return }
        let event = FaroEvent(name: "\(name)", domain: client.configuration.eventDomain, timestamp: timestamp(), attributes: attributes)
        client.recordThrottled(event, key: key ?? "\(name)", interval: interval, scrub: scrub)
    }

    /// An error the host handled: its Swift type and `errorValue`, with where it happened (`context`, a constant). The
    /// message is scrubbed when the item is queued, as `Configuration.scrubPolicy` says; `scrub` overrides that for this call
    /// (true: every free string, false: none). The same `scrub` parameter is on every recording function.
    public static func error(_ error: Error, _ context: StaticString, scrub: Bool? = nil) {
        guard let client else { return }
        client.record(.exception(FaroException(type: String(describing: type(of: error)), value: client.errorValue(error), timestamp: timestamp(),
                                               context: ["where": "\(context)"])), scrub: scrub)
    }

    /// A warning or error line: a constant message, a category, and optional low-cardinality context
    public static func log(_ level: FaroLog.Level, _ category: StaticString, _ message: StaticString, _ context: [String: String] = [:],
                           scrub: Bool? = nil) {
        guard let client else { return }
        client.record(.log(FaroLog(message: "\(message)", level: level, timestamp: timestamp(),
                                   context: logContext(context, category: "\(category)"))), scrub: scrub)
    }

    /// The log's context with the library's `category`, which wins over a caller's own `category` key: that key is exempt
    /// from scrubbing, so a caller's value there would bypass the scrub
    static func logContext(_ context: [String: String], category: String) -> [String: String] {
        context.merging(["category": category]) { _, library in library }
    }

    /// A measurement: a type and numeric values
    public static func measurement(_ type: StaticString, _ values: [String: Double], _ context: [String: String] = [:], scrub: Bool? = nil) {
        guard let client else { return }
        client.record(.measurement(FaroMeasurement(type: "\(type)", values: values, timestamp: timestamp(), context: context.isEmpty ? nil : context)), scrub: scrub)
    }

    // MARK: - Lifecycle

    /// The app went to the background: send what is queued (within a UIKit background task where there is one), keep the
    /// rest for the next launch
    @MainActor
    public static func applicationDidEnterBackground() {
        guard let client else { return }
        #if canImport(UIKit)
        let task = BackgroundTask()
        task.begin()
        Task {
            await client.flushAndPersist()
            task.end()
        }
        #else
        Task { await client.flushAndPersist() }
        #endif
    }

    /// Back in the foreground: what was kept for the next launch is still queued in memory, so the file goes (no
    /// duplicates at the next launch) and the queue is sent
    public static func applicationDidBecomeActive() {
        client?.foregrounded()
    }

    private static func timestamp() -> String {
        FaroTimestamp.string(Date())
    }
}

#if canImport(UIKit)
/// A UIKit background task that ends once, whichever comes first: the work or the system's expiry
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "telemetry-flush") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
