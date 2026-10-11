import Foundation
import os

#if DEBUG
/// `--dot-log <file>` on a Debug build appends one JSON line for each change
/// of the caret tracker's outcome and each placement or hiding of the dot:
/// the outcome's fixed name, the caret's rectangle, the dot's centre and
/// diameter in Accessibility's top-left screen coordinates, its ink and the
/// evidence it came from. `apps/macos/scripts/dot-matrix.sh` reads it to
/// compare the dot with the caret it measures itself. Geometry and fixed
/// names only, as the log store gets; never a field's text, a window's
/// title or an app's identity. Nothing is written without the argument.
enum DotLog {
    private static let url: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--dot-log"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }()
    /// The tracker writes from its own thread and the controller from the
    /// main thread; each line is appended whole.
    private static let lock = OSAllocatedUnfairLock(initialState: 0)

    /// The tracker's outcome changed to `reason`.
    static func tracker(_ reason: String) {
        write(["event": "tracker", "reason": reason])
    }

    /// The dot was placed from `source` (accessibility, hint, visual or
    /// held), or hidden when `center` is nil.
    static func dot(source: String, caret: CGRect? = nil, center: CGPoint? = nil, diameter: CGFloat? = nil, ink: Ink? = nil) {
        var record: [String: Any] = ["event": center == nil ? "dot-hidden" : "dot-placed", "source": source]
        if let caret { record["caret"] = ["x": caret.minX, "y": caret.minY, "width": caret.width, "height": caret.height] }
        if let center, let diameter { record["dot"] = ["x": center.x, "y": center.y, "diameter": diameter] }
        if let ink { record["ink"] = [ink.red, ink.green, ink.blue] }
        write(record)
    }

    private static func write(_ fields: [String: Any]) {
        guard let url else { return }
        var record = fields
        record["time"] = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        lock.withLock { count in
            guard count < 200_000 else { return }
            count += 1
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let file = try? FileHandle(forWritingTo: url) else { return }
            defer { try? file.close() }
            try? file.seekToEnd()
            try? file.write(contentsOf: data + Data([10]))
        }
    }
}
#endif
