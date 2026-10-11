import AppKit

#if DEBUG
/// Restricts the real app during synthetic integration checks. Parse before
/// constructing any tracker; malformed test arguments exit without capture.
@MainActor
enum CaretFixtureMode {
    struct Scope {
        let pid: pid_t
        let title: String
        let windowID: CGWindowID
        let visual: Bool
        let ready: String
    }

    static let scope: Scope? = {
        let args = CommandLine.arguments
        guard args.contains("--caret-fixture") else { return nil }
        func value(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let rawPID = value("--fixture-pid"), let pid = Int32(rawPID), pid > 0,
              let token = value("--fixture-token"), token.hasPrefix("Intention caret lab "),
              UUID(uuidString: String(token.dropFirst("Intention caret lab ".count))) != nil,
              let title = value("--fixture-title"), title.contains(token),
              let rawWindow = value("--fixture-window"), let windowID = UInt32(rawWindow),
              let visual = value("--fixture-visual"), ["on", "off"].contains(visual),
              let ready = value("--fixture-ready")
        else { exit(2) }
        return Scope(pid: pid, title: title, windowID: windowID, visual: visual == "on", ready: ready)
    }()

    private static var diagnosticCount = 0
    private static var dotDiagnosticCount = 0
    private static var drawDiagnosticCount = 0
    static func dotDraw(frame: CGRect, center: CGPoint) {
        guard let scope, drawDiagnosticCount < 10000 else { return }
        drawDiagnosticCount += 1
        let record: [String: Any] = ["time": ProcessInfo.processInfo.systemUptime,
            "schema": "stationary-surface-v1",
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
            "localCenter": ["x": center.x, "y": center.y]]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let url = URL(fileURLWithPath: scope.ready).deletingLastPathComponent().appendingPathComponent("dot-draw.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }
    static func anchorObservation(_ anchors: [CaretSearchAnchor], selection: Int?, readAt: TimeInterval) {
        guard let scope else { return }
        var record: [String: Any] = ["time": readAt,
            "anchors": anchors.map { anchor in
                ["source": anchor.source == .textRange ? "range" : "marker",
                 "x": anchor.bounds.minX, "y": anchor.bounds.minY,
                 "width": anchor.bounds.width, "height": anchor.bounds.height] as [String: Any]
            }]
        if let selection { record["selection"] = selection }
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let url = URL(fileURLWithPath: scope.ready).deletingLastPathComponent().appendingPathComponent("anchor-observation.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }
    /// Geometry produced by the real controller, available only to a scoped
    /// synthetic fixture. This is not screen-pixel evidence.
    static func dotObservation(caret: CGRect? = nil, center: CGPoint? = nil, diameter: CGFloat? = nil, ink: Ink? = nil) {
        guard let scope, dotDiagnosticCount < 10000 else { return }
        dotDiagnosticCount += 1
        var record: [String: Any] = ["event": center == nil ? "dot-hidden" : "dot-placed",
                                     "time": ProcessInfo.processInfo.systemUptime]
        if let caret {
            record["caret"] = ["x": caret.minX, "y": caret.minY, "width": caret.width, "height": caret.height]
        }
        if let center, let diameter {
            record["dot"] = ["x": center.x, "y": center.y, "diameter": diameter]
        }
        if let ink { record["ink"] = [ink.red, ink.green, ink.blue] }
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let url = URL(fileURLWithPath: scope.ready).deletingLastPathComponent().appendingPathComponent("dot-observation.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }
    static func diagnostic(_ event: String, duration: Double? = nil) {
        guard let scope, diagnosticCount < 4000 else { return }
        diagnosticCount += 1
        var record: [String: Any] = ["event": event, "time": ProcessInfo.processInfo.systemUptime]
        if let duration { record["duration_ms"] = duration * 1000 }
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let url = URL(fileURLWithPath: scope.ready).deletingLastPathComponent().appendingPathComponent("pipeline.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }

    static func acknowledgeReady() {
        guard let scope else { return }
        do {
            try String(getpid()).write(toFile: scope.ready, atomically: true, encoding: .utf8)
        } catch { exit(2) }
    }

    static func armDeadline() {
        guard scope != nil else { return }
        // A dead or interrupted runner cannot leave a capture process behind.
        Task {
            try? await Task.sleep(for: .seconds(90))
            exit(2)
        }
    }
}
#endif
