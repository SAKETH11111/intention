#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
build=$(mktemp -d /tmp/intention-isolation.XXXXXX)
trap 'rm -rf "$build"' EXIT
cat > "$build/Isolation.swift" <<'SWIFT'
import Foundation
import Darwin

@main
struct IsolationChecks {
    static func main() async throws {
        let origin = URL(string: "https://demo.example")!
        let client = try AlphaClient(endpoint: origin)
        let id = UUID().uuidString.lowercased()
        func check(_ method: String, _ path: String, _ expected: Bool) {
            var request = URLRequest(url: origin.appending(path: path))
            request.httpMethod = method
            precondition(AlphaClient.isDemoRequest(request, endpoint: origin) == expected, "Unexpected route policy")
        }
        for (method, path) in [("POST","v1/invites/redeem"),("GET","v1/me"),("POST","v1/speech/grants"),
                               ("POST","v1/speech/vocabulary"),("GET","v1/mail/connections"),
                               ("GET","v1/setup/reply-thread"),("POST","v1/writing/drafts"),
                               ("GET","v1/writing/drafts/\(id)"),("DELETE","v1/writing/drafts/\(id)"),
                               ("POST","v1/writing/drafts/\(id)/accept"),("POST","v1/writing/drafts/\(id)/shown")] {
            check(method,path,true)
        }
        for path in ["v1/retention/events","v1/retention/dictations/\(id)","v1/problem-reports",
                     "v1/mail/gmail/connect","v1/mail/outlook/connect","v1/mail/gmail/complete",
                     "v1/mail/connections/\(id)","v1/writing/drafts/not-a-uuid","v1/writing/drafts/\(id)/unknown"] {
            for method in ["GET","POST","PUT","DELETE"] { check(method,path,false) }
        }
        for url in ["http://demo.example/v1/me","https://other.example/v1/me","https://demo.example/v1/me?x=1"] {
            precondition(!AlphaClient.isDemoRequest(URLRequest(url: URL(string:url)!),endpoint:origin))
        }
        do { _ = try await client.beginMail(provider: .gmail, deviceKey: "synthetic-key"); preconditionFailure() }
        catch AlphaClient.MailFailure.couldNotOpen {}
        do { _ = try await client.disconnectMail(connectionID: UUID(), deviceKey: "synthetic-key"); preconditionFailure() }
        catch AlphaClient.MailFailure.couldNotOpen {}
        for address in ["http://localhost:4319", "http://127.0.0.1:4319", "https://demo.example"] {
            precondition(BackendAddress.isAlpha(URL(string: address)!))
        }
        for address in ["http://localhost", "http://127.0.0.2:4319", "http://example.com:4319", "http://localhost.evil.example:4319", "https://demo.example/private"] {
            precondition(!BackendAddress.isAlpha(URL(string: address)!))
        }
        for address in ["ws://localhost:4319/speech", "wss://demo.example/speech"] {
            precondition(BackendAddress.isSpeech(URL(string: address)!))
        }
        for address in ["ws://example.com:4319/speech", "ws://localhost:4319/private", "wss://demo.example/speech?token=x"] {
            precondition(!BackendAddress.isSpeech(URL(string: address)!))
        }
        precondition(DictationStream.isSameEndpoint(URL(string: "http://localhost:8787/speech"),
                                                  as: URL(string: "ws://localhost:8787/speech")))
        for actual in ["ws://other.example/speech", "ws://localhost:9999/speech", "ws://localhost:8787/other"] {
            precondition(!DictationStream.isSameEndpoint(URL(string: actual), as: URL(string: "ws://localhost:8787/speech")))
        }
        let invalid = DictationStream(url: URL(string: "ws://remote.example/speech")!, grant: "synthetic", start: .init(register: "other"))
        do {
            for try await _ in invalid.replies { preconditionFailure() }
            preconditionFailure()
        } catch DictationStreamError.unreachable {}
        let session = URLSession(configuration: .ephemeral)
        let suspendedTask = session.dataTask(with: URL(string: "http://localhost:8787/speech")!)
        let observed = NSLock()
        nonisolated(unsafe) var refused = false
        invalid.urlSession(session, task: suspendedTask,
                           willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "http://localhost:8787/speech")!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                           newRequest: URLRequest(url: URL(string: "https://other.example/speech")!)) { request in
            observed.withLock { refused = request == nil }
        }
        precondition(observed.withLock { refused })
        session.invalidateAndCancel()
        let candidate = try ProtectedInvite.parse("Demo invite 482913")
        precondition(candidate == "482913")
        let spaced = try ProtectedInvite.parse("Code 482 913")
        precondition(spaced == "482913")
        for invalid in ["12345", "1234567", "482913 or 728194", "no code"] {
            do { _ = try ProtectedInvite.parse(invalid); preconditionFailure() }
            catch ProtectedInvite.Failure.invalid {}
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.txt")
        try Data("Demo invite 482913".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let readCode = try ProtectedInvite.read(path: file.path)
        precondition(readCode == "482913")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        do { _ = try ProtectedInvite.read(path: file.path); preconditionFailure() }
        catch ProtectedInvite.Failure.unavailable {}
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try ProtectedInvite.read(path: link.path); preconditionFailure() }
        catch ProtectedInvite.Failure.unavailable {}
        let fifo = directory.appendingPathComponent("fifo")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        do { _ = try ProtectedInvite.read(path: fifo.path); preconditionFailure() }
        catch ProtectedInvite.Failure.unavailable {}
        print("Passed 81 transport, speech and protected invite isolation checks")
    }
}
SWIFT
xcrun swiftc -parse-as-library -swift-version 6 apps/macos/Intention/Platform/Backend/AlphaClient.swift \
  apps/macos/Intention/Platform/Backend/AlphaMail.swift apps/macos/Intention/Platform/Backend/DictationStream.swift apps/macos/Intention/Onboarding/ProtectedInvite.swift "$build/Isolation.swift" -o "$build/check"
"$build/check"
