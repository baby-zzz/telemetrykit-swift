import Foundation
import Testing
@testable import TelemetryKit

/// Scrubbing, sessions, the Faro wire format, the facade's gates, the queue's batching, retries and offline file, and the
/// configuration points.
struct TelemetryTests {
    // MARK: - Scrubbing

    @Test func scrubsCredentialQueryValues() {
        let redacted = TelemetryScrub.redacted
        #expect(TelemetryScrub.default.text("https://api.example.com/invite/1?signed=r_1-e_2-abc") == "https://api.example.com/invite/1?signed=\(redacted)")
        #expect(TelemetryScrub.default.text("https://app.example.com/auth/callback?state=s1&code=c1&lang=es")
            == "https://app.example.com/auth/callback?state=\(redacted)&code=\(redacted)&lang=es")
        #expect(TelemetryScrub.default.text("GET /reset/u?ts=17&Signed=x#top") == "GET /reset/u?ts=\(redacted)&Signed=\(redacted)#top")
        #expect(TelemetryScrub.default.text("no query here") == "no query here")
    }

    @Test func scrubsEmailsButNotPackageVersions() {
        let email = TelemetryScrub.emailRedacted
        #expect(TelemetryScrub.default.text("Invite failed for jane.doe+kid@example.co.uk: 409") == "Invite failed for \(email): 409")
        #expect(TelemetryScrub.default.text("https://app.example.com/register?email=jane@example.com&lang=es") == "https://app.example.com/register?email=\(email)&lang=es")
        let stack = "at render@https://app.example.com/assets/index.js:1:2 (faro-web-sdk@2.12.1)"
        #expect(TelemetryScrub.default.text(stack) == stack)
    }

    @Test func scrubsBearerTokensAndURLCredentials() {
        #expect(TelemetryScrub.default.text("Authorization: Bearer eyJ.abc-def") == "Authorization: Bearer [REDACTED]")
        #expect(TelemetryScrub.default.text("rtsp://admin:hunter2@192.168.1.20:554/stream1") == "rtsp://[REDACTED]@192.168.1.20:554/stream1")
    }

    @Test func itemsAreScrubbedButNamesKept() {
        let item = TelemetryItem.log(FaroLog(message: "Keychain write failed", level: .warn, timestamp: "t", context: ["url": "/x?token=1"]))
        guard case .log(let log) = item.scrubbed() else { Issue.record("not a log"); return }
        #expect(log.message == "Keychain write failed")
        #expect(log.context == ["url": "/x?token=[REDACTED]"])
        #expect(log.level == .warn)
        let exception = TelemetryItem.exception(FaroException(type: "URLError", value: "NSURLErrorDomain#-1001: timed out for a@b.com",
                                                              timestamp: "t", context: ["where": "alert"]))
        guard case .exception(let scrubbed) = exception.scrubbed() else { Issue.record("not an exception"); return }
        #expect(scrubbed.value == "NSURLErrorDomain#-1001: timed out for [email]")
    }

    @Test func errorsCarryTheirKindAndMessage() throws {
        let (client, _) = try Self.client()
        let error = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not open rtsp://admin:pw@10.0.0.2/s"])
        #expect(client.errorValue(error) == "Test#7: Could not open rtsp://admin:pw@10.0.0.2/s")
        #expect(TelemetryScrub.default.text(client.errorValue(error)) == "Test#7: Could not open rtsp://[REDACTED]@10.0.0.2/s")
        let long = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: String(repeating: "x", count: 2000)])
        #expect(client.errorValue(long).count == 500)
    }

    // MARK: - Sessions (the Faro web SDK's rules)

    @Test func sessionLastsUntilInactivity() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = TelemetrySession.next(nil, now: start, newID: { "s1" })
        #expect(first.isNew && first.session.id == "s1")
        let active = TelemetrySession.next(first.session, now: start + 14 * 60, newID: { "s2" })
        #expect(!active.isNew && active.session.id == "s1")
        let idle = TelemetrySession.next(active.session, now: start + 14 * 60 + TelemetrySession.defaultInactivityTimeout, newID: { "s3" })
        #expect(idle.isNew && idle.session.id == "s3")
        // kept busy, one session all night (no 4-hour cap)
        var session = first.session
        for minute in stride(from: 10, through: 12 * 60, by: 10) {
            let next = TelemetrySession.next(session, now: start + TimeInterval(minute * 60), newID: { "s4" })
            session = next.session
            #expect(!next.isNew)
        }
        #expect(session.id == "s1")
        #expect(TelemetrySession.randomID().count == 10)
    }

    // MARK: - Wire format

    @Test func payloadCarriesThePlatformFieldsTheDashboardsFilterOn() throws {
        let meta = Self.meta(user: "sub-1")
        let payload = FaroPayload(meta: meta, items: [.event(FaroEvent(name: "session_start", domain: "test", timestamp: "t", attributes: nil))])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let encodedMeta = try #require(json["meta"] as? [String: Any])
        let app = try #require(encodedMeta["app"] as? [String: Any])
        #expect(app["name"] as? String == "test-app")
        #expect(app["namespace"] as? String == "ios")
        #expect(app["bundleId"] as? String == "com.example.app")
        let session = try #require(encodedMeta["session"] as? [String: Any])
        #expect((session["attributes"] as? [String: String])?["platform"] == "ios")
        #expect((encodedMeta["user"] as? [String: Any])?["id"] as? String == "sub-1")
        #expect((encodedMeta["browser"] as? [String: Any])?["mobile"] as? Bool == true)
        #expect((json["events"] as? [[String: Any]])?.count == 1)
        #expect(json["logs"] == nil && json["exceptions"] == nil && json["measurements"] == nil)
    }

    @Test func timestampsAreRFC3339WithMilliseconds() {
        #expect(FaroTimestamp.string(Date(timeIntervalSince1970: 1_794_200_000.25)) == "2026-11-09T04:53:20.250Z")
    }

    // MARK: - Queue

    @Test func nothingIsSentUntilTheFlagSaysYes() async throws {
        let (client, transport) = try Self.client()
        client.record(Self.event("a"))
        #expect(client.pendingCount == 2) // session_start + a, held in memory
        #expect(await client.flush())
        #expect(await transport.bodies.isEmpty)
        client.setRemote(.disabled)
        #expect(client.pendingCount == 0)
        client.record(Self.event("b"))
        #expect(client.pendingCount == 0)
    }

    @Test func consentOffDropsTheQueueAndRecordsNothing() async throws {
        // Queued while the flag is not known yet, so no send can race the switch-off
        let (client, transport) = try Self.client()
        client.record(Self.event("a"))
        client.setConsent(false)
        #expect(client.pendingCount == 0)
        client.record(Self.event("b"))
        client.setRemote(.enabled)
        _ = await client.flush()
        #expect(await transport.bodies.isEmpty)
    }

    @Test func sendsOneRequestPerMetaWithSessionStartFirst() async throws {
        let (client, transport) = try Self.client(remote: .enabled)
        client.record(Self.event("before"))
        client.setUser("sub-1")
        client.record(Self.event("after"))
        #expect(await client.flush())
        let payloads = try await transport.payloads()
        #expect(payloads.count == 2)
        #expect(payloads[0].events?.map(\.name) == ["session_start", "before"])
        #expect(payloads[0].meta.user == nil)
        #expect(payloads[1].events?.map(\.name) == ["after"])
        #expect(payloads[1].meta.user?.id == "sub-1")
        #expect(payloads.allSatisfy { $0.meta.session?.id == payloads[0].meta.session?.id })
        #expect(client.pendingCount == 0)
    }

    @Test func serverErrorsAreRetriedAndRefusalsDropped() async throws {
        // A fixed clock: the 5 s backoff must not run out however slowly the test runs
        let box = ClockBox(Date(timeIntervalSince1970: 1_000))
        // The flag opens last: the flush it schedules then finds the whole queue (the first flush() below may join it)
        let (client, transport) = try Self.client(now: { box.now })
        await transport.respond([503])
        client.record(Self.event("a"))
        client.setRemote(.enabled)
        _ = await client.flush()
        #expect(client.pendingCount == 2) // back in the queue, waiting for the backoff
        #expect(await client.flush()) // still within the backoff: nothing sent
        #expect(await transport.bodies.count == 1)
        await transport.respond([400])
        client.foregrounded() // clears the backoff and schedules a send
        _ = await client.flush()
        #expect(client.pendingCount == 0) // refused: not retried
    }

    @Test func throttledEventsCountWhatWasSuppressed() throws {
        let box = ClockBox(Date(timeIntervalSince1970: 1_000))
        let (client, _) = try Self.client(remote: .unknown, now: { box.now })
        let event = FaroEvent(name: "socket_disconnected", domain: "test", timestamp: "t", attributes: ["reason": "x"])
        #expect(client.recordThrottled(event, key: "k", interval: 60))
        #expect(!client.recordThrottled(event, key: "k", interval: 60))
        #expect(!client.recordThrottled(event, key: "k", interval: 60))
        box.now += 61
        #expect(client.recordThrottled(event, key: "k", interval: 60))
        #expect(client.pendingCount == 3) // session_start + two sent
    }

    @Test func whatCouldNotBeSentIsKeptForTheNextLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appending(path: "pending.json")
        let (client, _) = try Self.client(store: store)
        client.record(Self.event("offline"))
        client.persist()
        #expect(FileManager.default.fileExists(atPath: store.path))

        let (next, transport) = try Self.client(store: store, remote: .enabled)
        next.restore()
        #expect(!FileManager.default.fileExists(atPath: store.path))
        #expect(next.pendingCount == 2)
        #expect(await next.flush())
        #expect(try await transport.payloads().flatMap { $0.events ?? [] }.map(\.name) == ["session_start", "offline"])

        // Older than a day: dropped
        let (old, _) = try Self.client(store: store)
        old.record(Self.event("stale"))
        old.persist()
        let (later, _) = try Self.client(store: store, now: { Date().addingTimeInterval(25 * 60 * 60) })
        later.restore()
        #expect(later.pendingCount == 0)
    }

    // MARK: - Configuration points

    @Test func eventDomainAndSessionAttributesComeFromTheConfiguration() async throws {
        var configuration = Self.configuration()
        configuration.eventDomain = "mydomain"
        configuration.sessionAttributes = ["platform": "macos", "channel": "beta"]
        let (client, transport) = try Self.client(remote: .enabled, configuration: configuration)
        client.record(.event(FaroEvent(name: "x", domain: client.configuration.eventDomain, timestamp: "t")))
        #expect(await client.flush())
        let payload = try #require(try await transport.payloads().first)
        #expect(payload.events?.map(\.domain) == ["mydomain", "mydomain"]) // session_start and x
        #expect(payload.meta.session?.attributes == ["platform": "macos", "channel": "beta"])
    }

    @Test func sdkDefaultsToThisLibrary() {
        #expect(FaroMeta.SDK.library == FaroMeta.SDK(name: "telemetrykit-swift", version: TelemetryKitInfo.version))
        let configuration = TelemetryClient.Configuration(endpoint: URL(string: "https://c.test/collect")!, app: Self.meta().app, browser: Self.meta().browser,
                                                          eventDomain: "d", consentKey: "c", debugOverrideKey: "o", sessionKey: "s", release: false)
        #expect(configuration.sdk == .library)
        #expect(configuration.consentDefault == false)
        #expect(configuration.maxErrorValueLength == 500 && configuration.maxBatch == 50 && configuration.sessionInactivityTimeout == 900)
    }

    @Test func extraScrubParametersAndPatterns() {
        let scrub = TelemetryScrub(extraParameters: ["invite_code", "a.b"], extraPatterns: ["ORD-[0-9]{6}"])
        #expect(scrub.text("/x?invite_code=abc&lang=en") == "/x?invite_code=[REDACTED]&lang=en")
        #expect(scrub.text("/x?a.b=1&axb=2") == "/x?a.b=[REDACTED]&axb=2") // names are literals
        #expect(scrub.text("order ORD-123456 failed") == "order [REDACTED] failed")
        #expect(scrub.text("/x?token=1&e=a@b.com") == "/x?token=[REDACTED]&e=[email]") // defaults stay
        #expect(TelemetryScrub.default.text("/x?invite_code=abc") == "/x?invite_code=abc")
    }

    @Test func aBrokenExtraPatternFailsClosed() {
        let scrub = TelemetryScrub(extraPatterns: ["(unclosed"])
        #expect(scrub.text("harmless") == TelemetryScrub.redacted)
    }

    @Test func configuredScrubIsAppliedWhenRecording() async throws {
        var configuration = Self.configuration()
        configuration.extraSecretParameters = ["invite"]
        configuration.extraScrubPatterns = ["ORD-[0-9]+"]
        let (client, transport) = try Self.client(remote: .enabled, configuration: configuration)
        client.record(.event(FaroEvent(name: "e", domain: "test", timestamp: "t", attributes: ["url": "/x?invite=1", "order": "ORD-77"])))
        #expect(await client.flush())
        let events = try await transport.payloads().flatMap { $0.events ?? [] }
        #expect(events.last?.attributes == ["url": "/x?invite=[REDACTED]", "order": "[REDACTED]"])
    }

    @Test func errorKindHookAndMaxLengthAreConfigurable() throws {
        var configuration = Self.configuration()
        configuration.errorKind = { _ in "custom-kind" }
        configuration.maxErrorValueLength = 20
        let (client, _) = try Self.client(configuration: configuration)
        let error = NSError(domain: "D", code: 3, userInfo: [NSLocalizedDescriptionKey: "a long description of the failure"])
        #expect(client.errorValue(error) == "custom-kind: a long ")
        #expect(client.errorValue(NSError(domain: "D", code: 3, userInfo: [NSLocalizedDescriptionKey: "custom-kind"])) == "custom-kind")
        // the default is domain#code
        #expect(TelemetryClient.Configuration.defaultErrorKind(error) == "D#3")
    }

    @Test func sessionInactivityTimeoutAndKeyAreConfigurable() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = TelemetrySession.next(nil, now: start, newID: { "a" })
        #expect(!TelemetrySession.next(first.session, now: start + 59, inactivityTimeout: 60, newID: { "b" }).isNew)
        #expect(TelemetrySession.next(first.session, now: start + 60, inactivityTimeout: 60, newID: { "b" }).isNew)

        let defaults = try #require(UserDefaults(suiteName: "telemetry-\(UUID().uuidString)"))
        var configuration = Self.configuration()
        configuration.sessionKey = "my_session_key"
        let (client, _) = try Self.client(configuration: configuration, defaults: defaults)
        client.record(Self.event("a"))
        #expect(defaults.data(forKey: "my_session_key") != nil)
        #expect(defaults.data(forKey: "test_session") == nil)
        // a second client on the same defaults resumes the session
        let (next, _) = try Self.client(configuration: configuration, defaults: defaults)
        #expect(next.currentSession?.id == client.currentSession?.id)
    }

    @Test func backoffAndBatchSizeAreConfigurable() async throws {
        let box = ClockBox(Date(timeIntervalSince1970: 1_000))
        var configuration = Self.configuration()
        configuration.backoff = [2]
        configuration.maxBatch = 2
        let (client, transport) = try Self.client(configuration: configuration, now: { box.now })
        await transport.respond([500])
        client.record(Self.event("a"))
        client.record(Self.event("b")) // session_start, a, b: batches of 2
        client.setRemote(.enabled)
        _ = await client.flush()
        #expect(await transport.bodies.count == 1)
        #expect(try await transport.payloads()[0].events?.count == 2)
        box.now += 1
        #expect(await client.flush()) // inside the 2 s backoff: nothing sent
        #expect(await transport.bodies.count == 1)
        box.now += 2
        #expect(await client.flush())
        #expect(client.pendingCount == 0)
    }

    @Test func storedFileLimitsAreConfigurable() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appending(path: "pending.json")
        var configuration = Self.configuration()
        configuration.maxStoredAge = 60
        let (client, _) = try Self.client(store: store, configuration: configuration)
        client.record(Self.event("a"))
        client.persist()
        let (later, _) = try Self.client(store: store, configuration: configuration, now: { Date().addingTimeInterval(120) })
        later.restore()
        #expect(later.pendingCount == 0)

        var small = Self.configuration()
        small.maxStoredBytes = 1
        let (tiny, _) = try Self.client(store: store, configuration: small)
        tiny.record(Self.event("a"))
        tiny.persist()
        #expect(!FileManager.default.fileExists(atPath: store.path)) // nothing fits, nothing is kept
    }

    @Test func buildAndConsentGatesUseTheConfiguredKeys() throws {
        let defaults = try #require(UserDefaults(suiteName: "telemetry-\(UUID().uuidString)"))
        var configuration = Self.configuration()
        configuration.release = false
        #expect(!Telemetry.buildAllows(configuration, defaults: defaults))
        defaults.set(true, forKey: "test_debug")
        #expect(Telemetry.buildAllows(configuration, defaults: defaults))
        configuration.release = true
        #expect(Telemetry.buildAllows(configuration, defaults: UserDefaults(suiteName: "telemetry-\(UUID().uuidString)") ?? defaults))

        // consent: the configured default until the key is set
        #expect(!Telemetry.consent(configuration, defaults: defaults))
        configuration.consentDefault = true
        #expect(Telemetry.consent(configuration, defaults: defaults))
        defaults.set(false, forKey: "test_consent")
        #expect(!Telemetry.consent(configuration, defaults: defaults))
    }

    @Test func facadeStartsOnlyWhereTheBuildAllowsAndFollowsConsent() throws {
        let defaults = try #require(UserDefaults(suiteName: "telemetry-\(UUID().uuidString)"))
        var configuration = Self.configuration()
        configuration.release = false
        Telemetry.start(configuration, defaults: defaults, transport: RecordingTelemetryTransport())
        #expect(Telemetry.client == nil)
        Telemetry.event("ignored") // no-op

        defaults.set(true, forKey: "test_debug")
        Telemetry.start(configuration, defaults: defaults, transport: RecordingTelemetryTransport())
        let client = try #require(Telemetry.client)
        defer { Telemetry.install(nil) }
        #expect(client.pendingCount == 0) // consent defaults to off
        Telemetry.setConsent(true)
        #expect(defaults.bool(forKey: "test_consent"))
        Telemetry.event("hello", ["k": "v"])
        #expect(client.pendingCount == 2)
        Telemetry.setRemoteEnabled(false)
        #expect(client.pendingCount == 0)
    }

    @Test func browserDescribesTheRunningSystem() {
        let browser = FaroMeta.Browser.describing(name: "App", version: "1.0", osName: "iOS", language: "es", mobile: true,
                                                  os: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0))
        #expect(browser.os == "iOS 26.1" && browser.language == "es" && browser.mobile)
        let patched = FaroMeta.Browser.describing(name: "App", version: "1.0", osName: "macOS", language: "en", mobile: false,
                                                  os: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 1))
        #expect(patched.os == "macOS 14.2.1")
    }

    // MARK: - Helpers

    static func configuration() -> TelemetryClient.Configuration {
        var configuration = TelemetryClient.Configuration(
            endpoint: URL(string: "https://collector.test/collect")!, app: meta().app, browser: meta().browser, eventDomain: "test",
            consentKey: "test_consent", debugOverrideKey: "test_debug", sessionKey: "test_session", release: true)
        configuration.sessionAttributes = ["platform": "ios"]
        configuration.flushDelay = 3600
        return configuration
    }

    static func meta(user: String? = nil) -> FaroMeta {
        FaroMeta(app: FaroMeta.App(name: "test-app", namespace: "ios", version: "1.0+1", environment: "development", bundleId: "com.example.app"),
                 sdk: FaroMeta.SDK(name: "telemetrykit-swift", version: "0.1.0"), session: FaroMeta.Session(id: "s", attributes: ["platform": "ios"]),
                 user: user.map { FaroMeta.User(id: $0) }, view: nil,
                 browser: FaroMeta.Browser(name: "Test-iOS", version: "1.0", os: "iOS 26.1", mobile: true, language: "en"))
    }

    static func event(_ name: String) -> TelemetryItem {
        .event(FaroEvent(name: name, domain: "test", timestamp: FaroTimestamp.string(Date()), attributes: nil))
    }

    /// A client whose timed flushes never fire during a test (`flushDelay` an hour), so only explicit `flush()` sends
    static func client(store: URL? = nil, remote: TelemetryClient.RemoteGate = .unknown, configuration: TelemetryClient.Configuration = configuration(),
                       defaults: UserDefaults? = nil, now: @escaping @Sendable () -> Date = Date.init) throws -> (TelemetryClient, RecordingTelemetryTransport) {
        let defaults = try defaults ?? #require(UserDefaults(suiteName: "telemetry-\(UUID().uuidString)"))
        let transport = RecordingTelemetryTransport()
        let client = TelemetryClient(configuration: configuration, transport: transport, defaults: defaults, storeURL: store, consent: true, now: now)
        if remote != .unknown { client.setRemote(remote) }
        return (client, transport)
    }
}

/// Records request bodies; answers 204 unless told otherwise
actor RecordingTelemetryTransport: TelemetryTransport {
    private(set) var bodies: [Data] = []
    private var statuses: [Int] = []

    func respond(_ statuses: [Int]) {
        self.statuses = statuses
    }

    func post(_ body: Data, to url: URL) async throws -> TelemetryResponse {
        bodies.append(body)
        return TelemetryResponse(status: statuses.isEmpty ? 204 : statuses.removeFirst(), retryAfter: nil)
    }

    func payloads() throws -> [FaroPayload] {
        try bodies.map { try JSONDecoder().decode(FaroPayload.self, from: $0) }
    }
}

nonisolated final class ClockBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
