/// Which free strings of an item are scrubbed (`TelemetryScrub`) when it is queued. Everything is on by default; turning
/// a field off sends its raw value, which is then the host app's responsibility. Names, types, levels, `where`,
/// timestamps and meta are never free text and are never scrubbed.
public struct ScrubPolicy: Sendable, Equatable {
    /// Values of an event's attributes
    public var eventAttributes: Bool
    /// A log's message
    public var logMessages: Bool
    /// Values of a log's context
    public var logContext: Bool
    /// An exception's value (the error message)
    public var exceptionValues: Bool
    /// Values of an exception's context
    public var exceptionContext: Bool
    /// Values of a measurement's context
    public var measurementContext: Bool

    public init(eventAttributes: Bool = true, logMessages: Bool = true, logContext: Bool = true,
                exceptionValues: Bool = true, exceptionContext: Bool = true, measurementContext: Bool = true) {
        self.eventAttributes = eventAttributes
        self.logMessages = logMessages
        self.logContext = logContext
        self.exceptionValues = exceptionValues
        self.exceptionContext = exceptionContext
        self.measurementContext = measurementContext
    }

    /// Every free string is scrubbed (the default)
    public static let all = ScrubPolicy()

    /// Nothing is scrubbed; the host app is responsible for what it records
    public static let none = ScrubPolicy(eventAttributes: false, logMessages: false, logContext: false,
                                         exceptionValues: false, exceptionContext: false, measurementContext: false)
}
