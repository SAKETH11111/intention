import AppKit

extension AppModel {
    /// Called by the menu before Intention opens the prompt, so the app id is
    /// the app the person was using. Only its bundle id is read.
    func makeProblemReport() -> ProblemReportSubmission {
        return ProblemReportSubmission(resolveKey: { diagnosticAccount?.refresh() }, makeReport: { key in
            let now = Date()
            let snapshot = DiagnosticEvents.shared.snapshot(at: now)
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let standings = onboarding.connections.map(OnboardingModel.standing)
            return ProblemReport(
                report_id: UUID(), text: nil,
                app_version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                app_build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                macos_version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                frontmost_bundle_id: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                captured_at: ProblemReport.timestamp(now),
                window_started_at: ProblemReport.timestamp(now.addingTimeInterval(-1800)),
                events: snapshot.events, events_truncated: snapshot.truncated,
                setup: .init(finished: onboarding.isFinished, signed_in: key != nil,
                             microphone: Microphone.permission == .authorized,
                             accessibility: permission.isGranted, screen_recording: CGPreflightScreenCaptureAccess()),
                mail_import: .init(known: onboarding.hasReadMail, read_failed: onboarding.mailReadFailed,
                                   connections: standings.count,
                                   importing: standings.filter { [.syncing, .checking, .retrying].contains($0) }.count,
                                   ready: standings.filter { $0 == .upToDate }.count,
                                   reconnect: standings.filter(\.isBroken).count))
        }, currentKey: { [weak onboarding] in onboarding?.backendKey },
           rejectKey: { [weak onboarding] in onboarding?.backendKeyRefused($0) }) { report, key in
            guard let client = AlphaClient.configured() else { throw ProblemReportSubmission.Failure.unavailable }
            try await client.reportProblem(report, deviceKey: key)
            DiagnosticEvents.shared.note(.reportProblem, interactionID: report.report_id)
        }
    }
}
