/// What a click on the foot mark asks of dictation. Start begins one
/// whenever none records, even while an earlier one's text is on its way;
/// done ends the recording and inserts its text, as a click on the dot
/// does; cancel, VoiceOver's other action on the listening sun, drops the
/// recording, inserts nothing and keeps nothing in history, and leaves any
/// earlier dictation to go in.
extension DictationController {
    func respond(to action: FootAction) {
        switch action {
        case .start: if phase != .recording { toggle() }
        case .done: if phase == .recording { toggle() }
        case .cancel: if phase == .recording { cancel() }
        }
    }
}
