import Foundation
import Darwin

/// Reads one owner-only local invite directly into the sign-in request.
/// The path is supplied at launch; neither the code nor file contents enter UI or logs.
enum ProtectedInvite {
    enum Failure: Error { case unavailable, invalid }

    static func read(path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              (1...1024).contains(info.st_size) else { throw Failure.unavailable }
        var bytes = [UInt8](repeating: 0, count: 1025)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count == Int(info.st_size), count <= 1024,
              let text = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw Failure.invalid }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> String {
        let pattern = #"(?<![0-9])(?:[0-9]{6}|[0-9]{3}[ -][0-9]{3})(?![0-9])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard matches.count == 1, let found = matches.first,
              let codeRange = Range(found.range, in: text) else { throw Failure.invalid }
        return text[codeRange].filter { $0.isASCII && $0.isNumber }
    }
}
