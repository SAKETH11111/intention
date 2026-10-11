/// Fixed event vocabulary shared by alpha tracking and local problem reports.
enum ClientEventName: String, Codable, CaseIterable, Sendable {
    case appLaunched = "app_launched", setupOpened = "setup_opened", signedIn = "signed_in"
    case permissionsGranted = "permissions_granted", firstSetupDictation = "first_setup_dictation"
    case mailboxConnected = "mailbox_connected", firstSetupEmail = "first_setup_email"
    case setupFinished = "setup_finished", firstDictation = "first_dictation", firstEmail = "first_email"
    case permissionMicrophoneGranted = "permission_microphone_granted"
    case permissionMicrophoneDenied = "permission_microphone_denied"
    case permissionAccessibilityGranted = "permission_accessibility_granted"
    case permissionAccessibilityDenied = "permission_accessibility_denied"
    case permissionScreenGranted = "permission_screen_granted", permissionScreenDenied = "permission_screen_denied"
    case dictationAttempt = "dictation_attempt", reportProblem = "report_problem"
    case dictationFinished = "dictation_finished", draftShown = "draft_shown", draftInserted = "draft_inserted"
    case draftDismissed = "draft_dismissed", draftOutcome = "draft_outcome"
    case fnReceived = "fn_received", fnShort = "fn_short", fnRejected = "fn_rejected"
    case fnListenerRebuilt = "fn_listener_rebuilt", fnSecureInput = "fn_secure_input"
    case proposalClient = "proposal_client", proposalGate = "proposal_gate"
}
enum ClientEventOutcome: String, Codable, CaseIterable, Sendable {
    case inserted, notInserted, uncertain, failed, cancelled, shown, accepted, dismissed, expired
    case refused, replaced, empty, unavailable, overtaken, dropped, insertRefused, notEligible
    case changed, hidden, ended, other, late, abstained, changeInserted, ignored, left, unconfirmed, limited, unreported
    case pressed, released, shortcut, click, start, trustChanged, secureInputEnded, disabled, healthCheck, monitorMiss, retry
    case heardNothing, heardAlmostNothing
    case failedRecord = "failed_record", failedTranscribe = "failed_transcribe", failedClean = "failed_clean"
    case failedEmail = "failed_email", failedInsert = "failed_insert"
}
