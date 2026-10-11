import Foundation
import XCTest
import os
@testable import Dictation

final class ProblemReportTests: XCTestCase {
    func testTransportUsesAuthenticatedRouteAndRequiresItsOwnReceipt() async throws {
        let report = Self.report()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProblemHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try AlphaClient(endpoint: URL(string: "https://service.invalid")!, session: session)
        ProblemHTTP.state.withLock { $0 = .init(id: report.report_id) }
        try await client.reportProblem(report, deviceKey: "synthetic-device-key")
        let request = try XCTUnwrap(ProblemHTTP.state.withLock { $0.request })
        XCTAssertEqual(request.url?.path, "/v1/problem-reports")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-device-key")
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        XCTAssertEqual(try JSONDecoder().decode(ProblemReport.self, from: data), report)
        ProblemHTTP.state.withLock { $0 = .init(id: UUID()) }
        do {
            try await client.reportProblem(report, deviceKey: "synthetic-device-key")
            XCTFail("Wrong report receipt must fail")
        } catch AlphaClient.Failure.invalidResponse {} catch { XCTFail("Unexpected failure") }
    }

    func testSuccessfulReportsWakeRecoveryButIdentityCannotWakeItsOwnRetry() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        AlphaClient.observeSuccessfulResponses { count.withLock { $0 += 1 } }
        defer { AlphaClient.observeSuccessfulResponses(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProblemHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try AlphaClient(endpoint: URL(string: "https://service.invalid")!, session: session)
        let report = Self.report()
        ProblemHTTP.state.withLock { $0 = .init(id: report.report_id) }
        try await client.reportProblem(report, deviceKey: "synthetic-key")
        XCTAssertEqual(count.withLock { $0 }, 1)
        // The receipt is deliberately not an identity response. A malformed
        // identity response must back off instead of waking its own retry.
        do { _ = try await client.identity(deviceKey: "synthetic-key"); XCTFail("Expected invalid identity") }
        catch is DecodingError {}
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func testSharedProtocolFixtureRoundTripsAndEnumsMatch() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["INTENTION_PROTOCOL_FIXTURES"])
        let fixture = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("problem-report.json"))
        let report = try JSONDecoder().decode(ProblemReport.self, from: fixture)
        let encoded = try JSONEncoder().encode(report)
        var fixtureObject = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        // UUID spelling is case-insensitive; Swift encodes its canonical uppercase form.
        fixtureObject["report_id"] = report.report_id.uuidString
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                       fixtureObject as NSDictionary)
        let enumData = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("problem-report-events.json"))
        let enums = try JSONDecoder().decode([String: [String]].self, from: enumData)
        XCTAssertEqual(Set(DiagnosticEvents.Name.allCases.map(\.rawValue)),
                       Set((enums["without_outcome"] ?? []) + (enums["with_outcome"] ?? [])))
        XCTAssertEqual(Set(DiagnosticEvents.Outcome.allCases.map(\.rawValue)), Set(enums["outcomes"] ?? []))
    }

    @MainActor
    func testRetryReusesExactReportAndChangedNoteGetsNewID() async throws {
        let received = Reports()
        let submission = ProblemReportSubmission(report: Self.report()) { report in
            await received.append(report)
            throw ProblemReportSubmission.Failure.sendFailed
        }
        for text in ["Synthetic note", "Synthetic note", "Changed note"] {
            do { try await submission.send(text: text); XCTFail("Expected failure") } catch {}
        }
        let reports = await received.values
        XCTAssertEqual(reports[0], reports[1])
        XCTAssertNotEqual(reports[1].report_id, reports[2].report_id)
        XCTAssertEqual(reports[2].text, "Changed note")
    }

    @MainActor
    func testSuccessIsSentOnceAndEmptyNoteIsNil() async throws {
        let received = Reports()
        let submission = ProblemReportSubmission(report: Self.report()) { await received.append($0) }
        try await submission.send(text: "")
        try await submission.send(text: "")
        let reports = await received.values
        XCTAssertEqual(reports.count, 1)
        XCTAssertNil(reports.first?.text)
    }

    @MainActor
    func testTextLimitCountsUnicodeScalarsBeforeUpload() async {
        let received = Reports()
        let submission = ProblemReportSubmission(report: Self.report()) { await received.append($0) }
        do {
            try await submission.send(text: String(repeating: "a", count: 4001))
            XCTFail("Expected text limit")
        } catch {}
        let reports = await received.values
        XCTAssertTrue(reports.isEmpty)
    }

    @MainActor
    func testCredentialResetCompletesBeforeCapturingAccountState() async throws {
        let received = Reports()
        let state = ReportAccountState()
        state.events = [.init(name: .dictationAttempt, outcome: nil, at: ProblemReport.timestamp(Date()))]
        state.mailConnections = 3
        let submission = ProblemReportSubmission(resolveKey: {
            state.events = []
            state.mailConnections = 0
            state.key = "replacement-key"
            return state.key
        }, makeReport: { key in
            XCTAssertEqual(key, "replacement-key")
            return Self.report(events: state.events, connections: state.mailConnections)
        }, currentKey: { state.key }, rejectKey: { _ in XCTFail("Unexpected refusal") }) { report, key in
            XCTAssertEqual(key, "replacement-key")
            await received.append(report)
        }
        try await submission.send(text: "")
        let reports = await received.values
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].events.isEmpty)
        XCTAssertEqual(reports[0].mail_import.connections, 0)
    }

    @MainActor
    func testUnauthorizedReportRoutesThroughRejectedKeyHandler() async throws {
        let state = ReportAccountState()
        let submission = ProblemReportSubmission(resolveKey: { state.key }, makeReport: { _ in Self.report() },
            currentKey: { state.key }, rejectKey: { key in
                state.refused.append(key)
                if state.key == key { state.key = nil }
            }, upload: { _, _ in throw AlphaClient.Failure.rejected(401) })
        do { try await submission.send(text: ""); XCTFail("Expected signed out") }
        catch ProblemReportSubmission.Failure.signedOut {}
        XCTAssertEqual(state.refused, ["original-key"])
        XCTAssertNil(state.key)
    }

    @MainActor
    func testAccountChangeBeforeSendRefusesCapturedSnapshot() async throws {
        let state = ReportAccountState()
        let submission = ProblemReportSubmission(resolveKey: { state.key }, makeReport: { _ in Self.report() },
            currentKey: { state.key }, rejectKey: { _ in XCTFail("Unexpected refusal") },
            upload: { _, _ in XCTFail("Old snapshot must not upload") })
        state.key = "replacement-key"
        do { try await submission.send(text: ""); XCTFail("Expected signed out") }
        catch ProblemReportSubmission.Failure.signedOut {}
    }

    @MainActor
    func testRateLimitPreservesRetryAfterAndBlocksChangedNotesUntilThen() async throws {
        let state = ReportAccountState()
        let before = Date()
        let limited = ProblemReportSubmission(resolveKey: { state.key }, makeReport: { _ in Self.report() },
            currentKey: { state.key }, rejectKey: { _ in XCTFail("Unexpected refusal") },
            upload: { _, _ in throw AlphaClient.Failure.tooManyRequests(retryAfter: 3600) })
        var deadline: Date?
        do { try await limited.send(text: ""); XCTFail("Expected limit") }
        catch let ProblemReportSubmission.Failure.rateLimited(until) { deadline = until }
        let retryAt = try XCTUnwrap(deadline)
        XCTAssertGreaterThanOrEqual(retryAt.timeIntervalSince(before), 3600)
        XCTAssertLessThan(retryAt.timeIntervalSince(before), 3605)

        let clock = OSAllocatedUnfairLock(initialState: before)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let submission = ProblemReportSubmission(report: Self.report(), now: { clock.withLock { $0 } }) { _ in
            let first = calls.withLock { value in value += 1; return value == 1 }
            if first { throw ProblemReportSubmission.Failure.rateLimited(until: retryAt) }
        }
        for note in ["original", "edited"] {
            do { try await submission.send(text: note); XCTFail("Expected limit") }
            catch let ProblemReportSubmission.Failure.rateLimited(until) { XCTAssertEqual(until, retryAt) }
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        clock.withLock { $0 = retryAt }
        try await submission.send(text: "edited")
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    private static func report(events: [DiagnosticEvents.Event] = [], connections: Int = 1) -> ProblemReport {
        .init(report_id: UUID(), text: nil, app_version: "0.1.3", app_build: "15", macos_version: "26.6.2",
              frontmost_bundle_id: "com.example.fixture", captured_at: "2026-10-09T20:00:00.000Z",
              window_started_at: "2026-10-09T19:30:00.000Z", events: events, events_truncated: false,
              setup: .init(finished: true, signed_in: true, microphone: true, accessibility: true, screen_recording: true),
              mail_import: .init(known: true, read_failed: false, connections: connections, importing: 0, ready: 1, reconnect: 0))
    }
}

private actor Reports {
    var values: [ProblemReport] = []
    func append(_ value: ProblemReport) { values.append(value) }
}

private final class ProblemHTTP: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        let id: UUID
        var request: URLRequest?
    }
    static let state = OSAllocatedUnfairLock(initialState: State(id: UUID()))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = Self.state.withLock { value in value.request = request; return value.id }
        let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"report_id\":\"\(id)\",\"status\":\"received\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class ReportAccountState {
    var key: String? = "original-key"
    var events: [DiagnosticEvents.Event] = []
    var mailConnections = 0
    var refused: [String] = []
}
