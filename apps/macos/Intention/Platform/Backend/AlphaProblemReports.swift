import Foundation

extension AlphaClient {
    func reportProblem(_ report: ProblemReport, deviceKey: String) async throws {
        throw ProblemReportSubmission.Failure.unavailable
    }
}

@MainActor
extension ProblemReportSubmission {
    /// Resolving a changed credential resets account state synchronously. Capture
    /// the report only after that reset, and keep it bound to this credential.
    convenience init(resolveKey: () -> String?, makeReport: (String?) -> ProblemReport,
                     currentKey: @escaping @MainActor @Sendable () -> String?,
                     rejectKey: @escaping @MainActor @Sendable (String) -> Void,
                     upload: @escaping @Sendable (ProblemReport, String) async throws -> Void) {
        let key = resolveKey()
        let report = makeReport(key)
        self.init(report: report) { report in
            guard let key, await currentKey() == key else { throw Failure.signedOut }
            do {
                try await upload(report, key)
            } catch AlphaClient.Failure.rejected(401) {
                await rejectKey(key)
                throw Failure.signedOut
            } catch let AlphaClient.Failure.tooManyRequests(retryAfter) {
                throw Failure.rateLimited(until: Date().addingTimeInterval(TimeInterval(max(1, retryAfter ?? 60))))
            }
        }
    }
}
