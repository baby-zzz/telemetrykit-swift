import Foundation
import os

/// Sends a batch to the Faro receiver; returns the HTTP status (tests replace it).
public protocol TelemetryTransport: Sendable {
    func post(_ body: Data, to url: URL) async throws -> TelemetryResponse
}

public struct TelemetryResponse: Equatable, Sendable {
    public var status: Int
    /// `Retry-After` in seconds (a 429 or 503)
    public var retryAfter: TimeInterval?

    public init(status: Int, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.retryAfter = retryAfter
    }
}

/// Its own ephemeral session: no cookies, no cache, nothing shared with the host app's sessions.
public struct URLSessionTelemetryTransport: TelemetryTransport {
    public init() {}

    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public func post(_ body: Data, to url: URL) async throws -> TelemetryResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return TelemetryResponse(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    }
}

/// The telemetry queue: records items with the meta of the moment, batches
/// them (every `flushDelay`, at `maxBatch` items, or when the app leaves), retries failures with backoff and keeps what
/// could not be sent in a small file until the next launch. Nothing is sent unless both the user's setting (`consent`,
/// on by default) and the server's flag (`remote`) allow it; while the flag is not known yet items wait in memory, and a
/// "no" from either drops everything queued. All state is behind one lock, so it can be called from any thread.
public final class TelemetryClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// The receiver's collect URL, e.g. `https://collector.example.com/collect`
        public var endpoint: URL
        public var app: FaroMeta.App
        public var browser: FaroMeta.Browser
        /// Defaults to this library (`telemetrykit-swift`)
        public var sdk: FaroMeta.SDK = .library
        /// Session attributes sent with every payload (each becomes `session_attr_<key>`), e.g. `["platform": "ios"]`
        public var sessionAttributes: [String: String] = [:]
        /// The `domain` of the events the facade records, e.g. `ios`
        public var eventDomain: String
        /// `UserDefaults` key of the user's consent (Bool)
        public var consentKey: String
        /// Consent when `consentKey` has never been set. Default false (opt-in); a host that offers an opt-out sets true.
        public var consentDefault = false
        /// `UserDefaults` key that lets a non-release build send (e.g. a launch argument `-MyTelemetry YES`)
        public var debugOverrideKey: String
        /// `UserDefaults` key of the persisted session
        public var sessionKey: String
        /// Whether this is a release build; others send only when `debugOverrideKey` is true
        public var release: Bool
        /// A stable, low-cardinality kind of an error (for grouping), put in front of its message. It must not include
        /// user info. Default `domain#code`.
        public var errorKind: @Sendable (Error) -> String = Configuration.defaultErrorKind
        /// The longest error value sent; longer ones are cut
        public var maxErrorValueLength = 500
        /// Seconds until a queued item is sent
        public var flushDelay: TimeInterval = 5
        public var maxBatch = 50
        public var maxPending = 500
        public var maxStoredBytes = 512 * 1024
        public var maxStoredAge: TimeInterval = 24 * 60 * 60
        /// Waits after the first, second... consecutive failure; the last repeats
        public var backoff: [TimeInterval] = [5, 30, 120, 600]
        /// A new session starts after this long without activity (there is no maximum session length)
        public var sessionInactivityTimeout: TimeInterval = TelemetrySession.defaultInactivityTimeout
        /// Extra secret query parameter names for the scrub
        public var extraSecretParameters: [String] = []
        /// Extra regular expressions for the scrub (each match becomes `[REDACTED]`)
        public var extraScrubPatterns: [String] = []
        /// Which free strings are scrubbed; default `.all`. Turning fields off sends raw values: that is the host's
        /// responsibility. A per-call `scrub:` overrides it.
        public var scrubPolicy: ScrubPolicy = .all

        public init(endpoint: URL, app: FaroMeta.App, browser: FaroMeta.Browser, eventDomain: String, consentKey: String,
                    debugOverrideKey: String, sessionKey: String, release: Bool) {
            self.endpoint = endpoint
            self.app = app
            self.browser = browser
            self.eventDomain = eventDomain
            self.consentKey = consentKey
            self.debugOverrideKey = debugOverrideKey
            self.sessionKey = sessionKey
            self.release = release
        }

        /// `domain#code`: no user info
        public static let defaultErrorKind: @Sendable (Error) -> String = { error in
            let nsError = error as NSError
            return "\(nsError.domain)#\(nsError.code)"
        }
    }

    /// The event `setUser` records for a new user, in `Configuration.eventDomain`
    private static let userIdentified = "user_identified"

    public enum RemoteGate: Sendable, Equatable {
        /// No answer from the host's flag yet: record, but only in memory
        case unknown
        case enabled
        case disabled
    }

    struct Pending: Codable, Equatable, Sendable {
        var meta: FaroMeta
        var item: TelemetryItem
        var recordedAt: Date
    }

    private struct Throttle: Sendable {
        var sentAt: Date
        var suppressed: Int
    }

    private struct State: Sendable {
        var pending: [Pending] = []
        var session: TelemetrySession?
        var userID: String?
        var view: String?
        var consent: Bool
        var remote: RemoteGate = .unknown
        var flushScheduled = false
        var sending = false
        /// The running drain; a `flush()` meanwhile joins it, then drains what it missed
        var drain: Task<Bool, Never>?
        var notBefore: Date?
        var failures = 0
        var throttled: [String: Throttle] = [:]
    }

    public let configuration: Configuration
    private let scrub: TelemetryScrub
    private let transport: any TelemetryTransport
    private let defaults: UserDefaults
    private let storeURL: URL?
    private let now: @Sendable () -> Date
    private let state: OSAllocatedUnfairLock<State>

    public init(configuration: Configuration, transport: any TelemetryTransport = URLSessionTelemetryTransport(), defaults: UserDefaults = .standard,
                storeURL: URL? = nil, consent: Bool, now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        scrub = TelemetryScrub(extraParameters: configuration.extraSecretParameters, extraPatterns: configuration.extraScrubPatterns)
        self.transport = transport
        self.defaults = defaults
        self.storeURL = storeURL
        self.now = now
        state = OSAllocatedUnfairLock(initialState: State(session: TelemetrySession.load(defaults, key: configuration.sessionKey), consent: consent))
    }

    // MARK: - Gates and identity

    public var pendingCount: Int { state.withLock { $0.pending.count } }
    /// Both gates are open: items are being sent
    public var isOpen: Bool { state.withLock { $0.consent && $0.remote == .enabled } }
    public var currentSession: TelemetrySession? { state.withLock { $0.session } }

    /// The user's setting : off drops everything queued or stored, at once
    public func setConsent(_ consent: Bool) {
        let open = state.withLock { state -> Bool in
            state.consent = consent
            if !consent { state.pending.removeAll() }
            return consent && state.remote == .enabled
        }
        if consent { if open { scheduleFlush(after: 0) } } else { deleteStore() }
    }

    /// The host's remote flag (kill switch, rollout)
    public func setRemote(_ gate: RemoteGate) {
        let open = state.withLock { state -> Bool in
            state.remote = gate
            if gate == .disabled { state.pending.removeAll() }
            return state.consent && gate == .enabled
        }
        if gate == .disabled { deleteStore() }
        if open { scheduleFlush(after: 0) }
    }

    /// An opaque user id after a sign-in, nil after a sign-out; items recorded from now on carry it. A new id (none
    /// before, or a different one) records `user_identified` with it, so a session that recorded nothing else since the
    /// sign-in still names its user; like any item it counts as activity (it may start a session) and passes the gates.
    /// The same id again, or nil, records nothing.
    public func setUser(_ id: String?) {
        guard let id, !id.isEmpty else {
            state.withLock { $0.userID = nil }
            return
        }
        enqueue(nil, identify: id)
    }

    public func setView(_ name: String?) {
        state.withLock { $0.view = name }
    }

    /// The error's kind (`Configuration.errorKind`) followed by its message, cut to `maxErrorValueLength`; scrubbed when the
    /// item is queued
    public func errorValue(_ error: Error) -> String {
        let kind = configuration.errorKind(error)
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = message.isEmpty || message == kind ? kind : "\(kind): \(message)"
        return String(value.prefix(configuration.maxErrorValueLength))
    }

    // MARK: - Recording

    /// - Parameter scrub: nil follows `Configuration.scrubPolicy`; true scrubs every free string of the item; false none
    public func record(_ item: TelemetryItem, scrub override: Bool? = nil) {
        let policy = override.map { $0 ? ScrubPolicy.all : .none } ?? configuration.scrubPolicy
        enqueue(item.scrubbed(with: scrub, policy: policy))
    }

    /// The app became active: counts as activity, so a session starts (`session_start`, nothing else) when none is
    /// running or the last one timed out, and a running one is extended. A no-op without consent or with the remote
    /// gate disabled, like recording.
    public func touchSession() {
        enqueue(nil)
    }

    /// Queues `item` (nil: only the session step). With `identify`, the user becomes that id first, in the same lock, and
    /// the item is `user_identified` (the library's own event, with no free strings, so like `session_start` it is not
    /// scrubbed); nothing is recorded when it is the current user already.
    private func enqueue(_ item: TelemetryItem?, identify: String? = nil) {
        let date = now()
        let outcome = state.withLock { state -> (session: TelemetrySession, flush: TimeInterval?)? in
            if let identify {
                guard identify != state.userID else { return nil }
                state.userID = identify
            }
            guard state.consent, state.remote != .disabled else { return nil }
            let clean = item ?? identify.map { _ in
                TelemetryItem.event(FaroEvent(name: Self.userIdentified, domain: configuration.eventDomain,
                                              timestamp: FaroTimestamp.string(date), attributes: nil))
            }
            let (session, isNew) = TelemetrySession.next(state.session, now: date, inactivityTimeout: configuration.sessionInactivityTimeout)
            state.session = session
            let meta = meta(state, session: session)
            if isNew {
                let start = FaroEvent(name: "session_start", domain: configuration.eventDomain, timestamp: FaroTimestamp.string(date), attributes: nil)
                state.pending.append(Pending(meta: meta, item: .event(start), recordedAt: date))
            }
            if let clean { state.pending.append(Pending(meta: meta, item: clean, recordedAt: date)) }
            if !isNew && clean == nil { return (session, nil) }
            if state.pending.count > configuration.maxPending { state.pending.removeFirst(state.pending.count - configuration.maxPending) }
            guard state.remote == .enabled else { return (session, nil) }
            if state.pending.count >= configuration.maxBatch { return (session, 0) }
            return (session, state.flushScheduled ? nil : configuration.flushDelay)
        }
        guard let outcome else { return }
        outcome.session.save(defaults, key: configuration.sessionKey)
        if let delay = outcome.flush { scheduleFlush(after: delay) }
    }

    /// At most one per `interval` per `key`; the one sent carries `suppressed`, how many were dropped since . Returns whether it was recorded.
    @discardableResult
    public func recordThrottled(_ event: FaroEvent, key: String, interval: TimeInterval, scrub: Bool? = nil) -> Bool {
        let date = now()
        let suppressed = state.withLock { state -> Int? in
            if let entry = state.throttled[key], date.timeIntervalSince(entry.sentAt) < interval {
                state.throttled[key]?.suppressed += 1
                return nil
            }
            let dropped = state.throttled[key]?.suppressed ?? 0
            state.throttled[key] = Throttle(sentAt: date, suppressed: 0)
            return dropped
        }
        guard let suppressed else { return false }
        var event = event
        event.attributes = (event.attributes ?? [:]).merging(["suppressed": String(suppressed)]) { _, new in new }
        record(.event(event), scrub: scrub)
        return true
    }

    private func meta(_ state: State, session: TelemetrySession) -> FaroMeta {
        FaroMeta(app: configuration.app, sdk: configuration.sdk,
                 session: FaroMeta.Session(id: session.id, attributes: configuration.sessionAttributes),
                 user: state.userID.map { FaroMeta.User(id: $0) }, view: state.view.map { FaroMeta.View(name: $0) },
                 browser: configuration.browser)
    }

    // MARK: - Sending

    private func scheduleFlush(after delay: TimeInterval) {
        if delay > 0 {
            let first = state.withLock { state -> Bool in
                defer { state.flushScheduled = true }
                return !state.flushScheduled
            }
            guard first else { return }
        }
        Task.detached { [self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if delay > 0 { state.withLock { $0.flushScheduled = false } }
            await flush()
        }
    }

    /// The next batch, or nil when there is nothing to send now; nil also ends the running drain (atomically, so an
    /// item recorded right after schedules a flush of its own)
    private func takeBatch() -> [Pending]? {
        let date = now()
        return state.withLock { state -> [Pending]? in
            guard state.consent, state.remote == .enabled, !state.sending, !state.pending.isEmpty,
                  state.notBefore.map({ date >= $0 }) ?? true else {
                state.drain = nil
                return nil
            }
            state.sending = true
            let count = min(configuration.maxBatch, state.pending.count)
            let batch = Array(state.pending.prefix(count))
            state.pending.removeFirst(count)
            return batch
        }
    }

    /// Sends everything queued while allowed. Returns false when a batch failed (it is queued again, with backoff).
    /// Only one drain runs at a time: a call during another one waits for it and then sends what it left.
    @discardableResult
    public func flush() async -> Bool {
        while true {
            let (task, mine) = state.withLock { state -> (Task<Bool, Never>, Bool) in
                if let running = state.drain { return (running, false) }
                let task = Task.detached { [self] in await drainQueue() }
                state.drain = task
                return (task, true)
            }
            let result = await task.value
            if mine { return result }
        }
    }

    private func drainQueue() async -> Bool {
        while let batch = takeBatch() {
            var failed: [Pending] = []
            var retryAfter: TimeInterval?
            for group in Self.groupedByMeta(batch) {
                guard let body = try? JSONEncoder().encode(FaroPayload(meta: group[0].meta, items: group.map(\.item))) else { continue }
                do {
                    let response = try await transport.post(body, to: configuration.endpoint)
                    switch response.status {
                    case 200..<300: break
                    // Overloaded or down: try again later
                    case 408, 429, 500...599:
                        failed += group
                        retryAfter = response.retryAfter ?? retryAfter
                    // Refused (bad payload, gone): sending it again would not help
                    default: break
                    }
                } catch {
                    failed += group
                }
            }
            let wait = finishBatch(failed: failed, retryAfter: retryAfter)
            if let wait {
                scheduleFlush(after: wait)
                return false
            }
        }
        return true
    }

    /// Re-queues a failed batch ahead of newer items and returns how long to wait, or nil after a success
    private func finishBatch(failed: [Pending], retryAfter: TimeInterval?) -> TimeInterval? {
        let date = now()
        return state.withLock { state -> TimeInterval? in
            state.sending = false
            guard !failed.isEmpty else {
                // the drain goes on: takeBatch ends it
                state.failures = 0
                state.notBefore = nil
                return nil
            }
            state.drain = nil
            state.failures += 1
            let backoff = configuration.backoff[min(state.failures - 1, configuration.backoff.count - 1)]
            let wait = max(retryAfter ?? 0, backoff)
            state.notBefore = date.addingTimeInterval(wait)
            if state.consent, state.remote != .disabled {
                state.pending.insert(contentsOf: failed, at: 0)
                if state.pending.count > configuration.maxPending { state.pending.removeFirst(state.pending.count - configuration.maxPending) }
            }
            return wait
        }
    }

    /// Consecutive items with the same meta go in one request (a sign-in or a new session starts a new one)
    static func groupedByMeta(_ items: [Pending]) -> [[Pending]] {
        var groups: [[Pending]] = []
        for item in items {
            if let last = groups.last?.last, last.meta == item.meta {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        return groups
    }

    // MARK: - Leaving the app and coming back

    /// The app goes to the background: send what is queued, keep what could not be sent for the next launch
    public func flushAndPersist() async {
        state.withLock { $0.notBefore = nil }
        await flush()
        persist()
    }

    /// Back in the foreground: the queue is still in memory, so the stored copy goes; send now
    public func foregrounded() {
        deleteStore()
        state.withLock { $0.notBefore = nil }
        if isOpen { scheduleFlush(after: 0) }
    }

    /// Writes what is still queued (oldest dropped beyond `maxStoredBytes`); only while the user's setting allows it
    public func persist() {
        guard let storeURL else { return }
        let items = state.withLock { state -> [Pending] in
            guard state.consent, state.remote != .disabled else { return [] }
            return state.pending
        }
        guard !items.isEmpty else {
            deleteStore()
            return
        }
        var kept = items[...]
        while !kept.isEmpty {
            if let data = try? JSONEncoder().encode(Array(kept)), data.count <= configuration.maxStoredBytes {
                try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                #if os(iOS) || os(tvOS) || os(watchOS)
                try? data.write(to: storeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try? data.write(to: storeURL, options: [.atomic])
                #endif
                return
            }
            kept = kept.dropFirst(max(1, kept.count / 2))
        }
        deleteStore()
    }

    /// At launch: what the last run could not send (younger than `maxStoredAge`) goes ahead of new items; the file is removed
    public func restore() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL) else { return }
        deleteStore()
        guard let stored = try? JSONDecoder().decode([Pending].self, from: data) else { return }
        let date = now()
        let fresh = stored.filter { date.timeIntervalSince($0.recordedAt) < configuration.maxStoredAge }
        state.withLock { state in
            guard state.consent, state.remote != .disabled else { return }
            state.pending.insert(contentsOf: fresh, at: 0)
            if state.pending.count > configuration.maxPending { state.pending.removeFirst(state.pending.count - configuration.maxPending) }
        }
    }

    private func deleteStore() {
        guard let storeURL else { return }
        try? FileManager.default.removeItem(at: storeURL)
    }
}
