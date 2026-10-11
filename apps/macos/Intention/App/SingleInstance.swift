import Foundation

/// Allows one running instance per bundle identifier, so builds from
/// different worktrees cannot draw two dots.
///
/// Uses an advisory file lock that the system releases when the process
/// exits, including after a crash.
enum SingleInstance {
    private nonisolated(unsafe) static var descriptor: Int32 = -1

    /// Returns false if another instance holds the lock.
    static func acquire(bundleIdentifier: String) -> Bool {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }
}
