import Foundation

/// A telemetry session: a random id that lasts until `inactivityTimeout` without activity (default 15 minutes), persisted
/// across launches in `UserDefaults`. Unlike the Faro web SDK there is no maximum length: a device that is busy all night
/// is one session. A new session records a `session_start` event.
public struct TelemetrySession: Codable, Equatable, Sendable {
    public static let defaultInactivityTimeout: TimeInterval = 15 * 60

    public var id: String
    public var startedAt: Date
    public var lastActivity: Date

    /// The session an item recorded at `now` belongs to, and whether it is a new one
    public static func next(_ current: TelemetrySession?, now: Date, inactivityTimeout: TimeInterval = defaultInactivityTimeout,
                            newID: () -> String = randomID) -> (session: TelemetrySession, isNew: Bool) {
        if var session = current, now.timeIntervalSince(session.lastActivity) < inactivityTimeout,
           now >= session.startedAt {
            session.lastActivity = max(session.lastActivity, now)
            return (session, false)
        }
        return (TelemetrySession(id: newID(), startedAt: now, lastActivity: now), true)
    }

    /// 10 alphanumerics, the Faro web SDK's session id format
    public static func randomID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<10).map { _ in alphabet.randomElement() ?? "0" })
    }

    static func load(_ defaults: UserDefaults, key: String) -> TelemetrySession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TelemetrySession.self, from: data)
    }

    func save(_ defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}
