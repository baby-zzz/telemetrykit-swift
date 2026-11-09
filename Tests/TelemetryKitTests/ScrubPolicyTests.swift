import Foundation
import Testing
@testable import TelemetryKit

/// `ScrubPolicy`, `Configuration.scrubPolicy` and the per-call `scrub:` override.
struct ScrubPolicyTests {
    private static let secret = "mail jane@example.com"
    private static let clean = "mail [email]"

    private enum Field: CaseIterable { case eventAttributes, logMessages, logContext, exceptionValues, exceptionContext, measurementContext }

    /// One of each item, every free string holding an e-mail address
    private static func items() -> [TelemetryItem] {
        [.event(FaroEvent(name: "e", domain: "d", timestamp: "t", attributes: ["a": secret])),
         .log(FaroLog(message: secret, level: .warn, timestamp: "t", context: ["c": secret, "category": "cat"])),
         .exception(FaroException(type: "T", value: secret, timestamp: "t", context: ["where": "w", "x": secret])),
         .measurement(FaroMeasurement(type: "m", values: ["v": 1], timestamp: "t", context: ["c": secret]))]
    }

    /// Which fields came out scrubbed
    private static func scrubbedFields(_ items: [TelemetryItem]) -> Set<Field> {
        var out: Set<Field> = []
        for item in items {
            switch item {
            case .event(let event): if event.attributes?["a"] == clean { out.insert(.eventAttributes) }
            case .log(let log):
                if log.message == clean { out.insert(.logMessages) }
                if log.context?["c"] == clean { out.insert(.logContext) }
            case .exception(let exception):
                if exception.value == clean { out.insert(.exceptionValues) }
                if exception.context?["x"] == clean { out.insert(.exceptionContext) }
            case .measurement(let measurement): if measurement.context?["c"] == clean { out.insert(.measurementContext) }
            }
        }
        return out
    }

    private static func sent(policy: ScrubPolicy = .all, patterns: [String] = [], scrub: Bool? = nil) async throws -> [TelemetryItem] {
        var configuration = TelemetryTests.configuration()
        configuration.scrubPolicy = policy
        configuration.extraScrubPatterns = patterns
        let (client, transport) = try TelemetryTests.client(remote: .enabled, configuration: configuration)
        for item in items() { client.record(item, scrub: scrub) }
        await client.flush()
        var out: [TelemetryItem] = []
        for body in await transport.bodies {
            let payload = try JSONDecoder().decode(FaroPayload.self, from: body)
            out += (payload.events ?? []).filter { $0.name != "session_start" }.map { .event($0) }
            out += (payload.logs ?? []).map { .log($0) }
            out += (payload.exceptions ?? []).map { .exception($0) }
            out += (payload.measurements ?? []).map { .measurement($0) }
        }
        return out
    }

    private static func policy(only field: Field) -> ScrubPolicy {
        var policy = ScrubPolicy.none
        switch field {
        case .eventAttributes: policy.eventAttributes = true
        case .logMessages: policy.logMessages = true
        case .logContext: policy.logContext = true
        case .exceptionValues: policy.exceptionValues = true
        case .exceptionContext: policy.exceptionContext = true
        case .measurementContext: policy.measurementContext = true
        }
        return policy
    }

    @Test func presets() {
        #expect(ScrubPolicy.all == ScrubPolicy())
        #expect(ScrubPolicy.all != ScrubPolicy.none)
        #expect(TelemetryTests.configuration().scrubPolicy == .all)
    }

    @Test func defaultScrubsEverything() async throws {
        let items = try await Self.sent()
        #expect(Self.scrubbedFields(items) == Set(Field.allCases))
    }

    @Test func noneSendsRawValues() async throws {
        let items = try await Self.sent(policy: .none)
        #expect(Self.scrubbedFields(items).isEmpty)
        #expect(items.contains(.event(FaroEvent(name: "e", domain: "d", timestamp: "t", attributes: ["a": Self.secret]))))
    }

    @Test(arguments: Field.allCases)
    private func eachFieldIndependently(_ field: Field) async throws {
        let only = try await Self.sent(policy: Self.policy(only: field))
        #expect(Self.scrubbedFields(only) == [field])
        var all = ScrubPolicy.all
        switch field {
        case .eventAttributes: all.eventAttributes = false
        case .logMessages: all.logMessages = false
        case .logContext: all.logContext = false
        case .exceptionValues: all.exceptionValues = false
        case .exceptionContext: all.exceptionContext = false
        case .measurementContext: all.measurementContext = false
        }
        let rest = try await Self.sent(policy: all)
        #expect(Self.scrubbedFields(rest) == Set(Field.allCases).subtracting([field]))
    }

    @Test func callerKeysNamedLikeLibraryKeysAreStillScrubbed() async throws {
        var configuration = TelemetryTests.configuration()
        configuration.scrubPolicy = .all
        let (client, transport) = try TelemetryTests.client(remote: .enabled, configuration: configuration)
        client.record(.event(FaroEvent(name: "e", domain: "d", timestamp: "t", attributes: ["category": Self.secret, "where": Self.secret])))
        client.record(.measurement(FaroMeasurement(type: "m", values: [:], timestamp: "t", context: ["category": Self.secret, "where": Self.secret])))
        await client.flush()
        let payload = try JSONDecoder().decode(FaroPayload.self, from: #require(await transport.bodies.first))
        let event = try #require(payload.events?.first { $0.name == "e" })
        #expect(event.attributes == ["category": Self.clean, "where": Self.clean])
        #expect(payload.measurements?.first?.context == ["category": Self.clean, "where": Self.clean])
    }

    @Test func perCallTrueBeatsNonePolicy() async throws {
        let items = try await Self.sent(policy: .none, scrub: true)
        #expect(Self.scrubbedFields(items) == Set(Field.allCases))
    }

    @Test func perCallFalseBeatsAllPolicy() async throws {
        let items = try await Self.sent(policy: .all, scrub: false)
        #expect(Self.scrubbedFields(items).isEmpty)
    }

    @Test func perCallNilFollowsThePolicy() async throws {
        let items = try await Self.sent(policy: Self.policy(only: .logContext), scrub: nil)
        #expect(Self.scrubbedFields(items) == [.logContext])
    }

    @Test func failsClosedWhenScrubbingRuns() async throws {
        let items = try await Self.sent(policy: .all, patterns: ["("])
        for item in items {
            switch item {
            case .event(let event): #expect(event.attributes?["a"] == TelemetryScrub.redacted)
            case .log(let log): #expect(log.message == TelemetryScrub.redacted && log.context?["c"] == TelemetryScrub.redacted)
                #expect(log.context?["category"] == "cat")
            case .exception(let exception):
                #expect(exception.value == TelemetryScrub.redacted && exception.context?["x"] == TelemetryScrub.redacted)
                #expect(exception.context?["where"] == "w")
            case .measurement(let measurement): #expect(measurement.context?["c"] == TelemetryScrub.redacted)
            }
        }
        // a per-call true runs the scrub even under .none
        let forced = try await Self.sent(policy: .none, patterns: ["("], scrub: true)
        #expect(forced.count == 4)
        for case .event(let event) in forced { #expect(event.attributes?["a"] == TelemetryScrub.redacted) }
        // and a per-call false skips it
        let skipped = try await Self.sent(policy: .all, patterns: ["("], scrub: false)
        #expect(Self.scrubbedFields(skipped).isEmpty)
        for case .event(let event) in skipped { #expect(event.attributes?["a"] == Self.secret) }
    }
}
