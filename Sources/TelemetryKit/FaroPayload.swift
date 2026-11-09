import Foundation

/// The Faro receiver's JSON body (`POST <endpoint>`, Alloy `faro.receiver`): the subset this client sends. The receiver
/// turns `meta` into logfmt keys on every log line (`app_name`, `session_id`, `user_id`, `browser_os`, `view_name`...), so
/// the field names are the Faro web SDK's.
public struct FaroPayload: Codable, Equatable, Sendable {
    public var meta: FaroMeta
    public var events: [FaroEvent]?
    public var logs: [FaroLog]?
    public var exceptions: [FaroException]?
    public var measurements: [FaroMeasurement]?

    public init(meta: FaroMeta, items: [TelemetryItem]) {
        self.meta = meta
        var events: [FaroEvent] = [], logs: [FaroLog] = [], exceptions: [FaroException] = [], measurements: [FaroMeasurement] = []
        for item in items {
            switch item {
            case .event(let event): events.append(event)
            case .log(let log): logs.append(log)
            case .exception(let exception): exceptions.append(exception)
            case .measurement(let measurement): measurements.append(measurement)
            }
        }
        self.events = events.isEmpty ? nil : events
        self.logs = logs.isEmpty ? nil : logs
        self.exceptions = exceptions.isEmpty ? nil : exceptions
        self.measurements = measurements.isEmpty ? nil : measurements
    }
}

public struct FaroMeta: Codable, Equatable, Hashable, Sendable {
    public struct App: Codable, Equatable, Hashable, Sendable {
        public var name: String
        /// Often the platform (`ios`): a fallback filter key (`app_namespace`)
        public var namespace: String
        public var version: String
        /// `production` / `development`
        public var environment: String
        public var bundleId: String

        public init(name: String, namespace: String, version: String, environment: String, bundleId: String) {
            self.name = name
            self.namespace = namespace
            self.version = version
            self.environment = environment
            self.bundleId = bundleId
        }
    }

    public struct SDK: Codable, Equatable, Hashable, Sendable {
        public var name: String
        public var version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }

        /// This library, as the default SDK identity
        public static let library = SDK(name: TelemetryKitInfo.name, version: TelemetryKitInfo.version)
    }

    public struct Session: Codable, Equatable, Hashable, Sendable {
        public var id: String
        /// Each attribute becomes `session_attr_<key>` on the receiver's log lines
        public var attributes: [String: String]

        public init(id: String, attributes: [String: String]) {
            self.id = id
            self.attributes = attributes
        }
    }

    public struct User: Codable, Equatable, Hashable, Sendable {
        /// An opaque identifier only; never an e-mail address or a name
        public var id: String

        public init(id: String) { self.id = id }
    }

    public struct View: Codable, Equatable, Hashable, Sendable {
        public var name: String

        public init(name: String) { self.name = name }
    }

    public struct Browser: Codable, Equatable, Hashable, Sendable {
        public var name: String
        public var version: String
        /// e.g. `iOS 26.1`
        public var os: String
        public var mobile: Bool
        public var language: String

        public init(name: String, version: String, os: String, mobile: Bool, language: String) {
            self.name = name
            self.version = version
            self.os = os
            self.mobile = mobile
            self.language = language
        }

        /// A browser entry whose `os` reads "<osName> <major>.<minor>[.<patch>]" for the running system
        public static func describing(name: String, version: String, osName: String, language: String, mobile: Bool,
                                      os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Browser {
            let osVersion = os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" : "\(os.majorVersion).\(os.minorVersion)"
            return Browser(name: name, version: version, os: "\(osName) \(osVersion)", mobile: mobile, language: language)
        }
    }

    public var app: App
    public var sdk: SDK
    public var session: Session?
    public var user: User?
    public var view: View?
    public var browser: Browser

    public init(app: App, sdk: SDK, session: Session? = nil, user: User? = nil, view: View? = nil, browser: Browser) {
        self.app = app
        self.sdk = sdk
        self.session = session
        self.user = user
        self.view = view
        self.browser = browser
    }
}

public struct FaroEvent: Codable, Equatable, Sendable {
    public var name: String
    public var domain: String
    public var timestamp: String
    public var attributes: [String: String]?

    public init(name: String, domain: String, timestamp: String, attributes: [String: String]? = nil) {
        self.name = name
        self.domain = domain
        self.timestamp = timestamp
        self.attributes = attributes
    }
}

public struct FaroLog: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable {
        case warn, error
    }

    public var message: String
    public var level: Level
    public var timestamp: String
    public var context: [String: String]?

    public init(message: String, level: Level, timestamp: String, context: [String: String]? = nil) {
        self.message = message
        self.level = level
        self.timestamp = timestamp
        self.context = context
    }
}

public struct FaroException: Codable, Equatable, Sendable {
    /// The Swift type, e.g. `APIError`
    public var type: String
    /// An error kind (`TelemetryClient.Configuration.errorKind`) and the error's message, scrubbed
    public var value: String
    public var timestamp: String
    public var context: [String: String]?

    public init(type: String, value: String, timestamp: String, context: [String: String]? = nil) {
        self.type = type
        self.value = value
        self.timestamp = timestamp
        self.context = context
    }
}

public struct FaroMeasurement: Codable, Equatable, Sendable {
    public var type: String
    public var values: [String: Double]
    public var timestamp: String
    public var context: [String: String]?

    public init(type: String, values: [String: Double], timestamp: String, context: [String: String]? = nil) {
        self.type = type
        self.values = values
        self.timestamp = timestamp
        self.context = context
    }
}

/// One queued signal; the meta it is sent with is captured when it is recorded.
public enum TelemetryItem: Codable, Equatable, Sendable {
    case event(FaroEvent)
    case log(FaroLog)
    case exception(FaroException)
    case measurement(FaroMeasurement)

    /// The same item with every free string scrubbed. Names, types and log messages are the host's own constants
    /// (`StaticString` in the facade) and are sent as they are.
    public func scrubbed(with scrub: TelemetryScrub = .default) -> TelemetryItem {
        func scrubMap(_ map: [String: String]?) -> [String: String]? { map?.mapValues { scrub.text($0) } }
        switch self {
        case .event(var event):
            event.attributes = scrubMap(event.attributes)
            return .event(event)
        case .log(var log):
            log.context = scrubMap(log.context)
            return .log(log)
        case .exception(var exception):
            exception.value = scrub.text(exception.value)
            exception.context = scrubMap(exception.context)
            return .exception(exception)
        case .measurement(var measurement):
            measurement.context = scrubMap(measurement.context)
            return .measurement(measurement)
        }
    }
}

public enum FaroTimestamp {
    /// RFC 3339 with milliseconds, UTC, as the Faro web SDK sends
    public static func string(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// The library's own identity, the default `sdk` of the meta
public enum TelemetryKitInfo {
    public static let name = "telemetrykit-swift"
    public static let version = "0.1.0" // x-release-please-version
}
