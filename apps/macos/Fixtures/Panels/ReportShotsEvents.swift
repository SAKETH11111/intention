// The report fixture draws the prompt, which never reads events, so
// `ProblemReport`'s event type stands in for the real ring here instead of
// compiling the timings and records it is built from.
enum DiagnosticEvents {
    struct Event: Codable, Sendable, Equatable {}
}
