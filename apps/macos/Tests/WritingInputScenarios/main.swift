import Foundation

// A Foundation-only executable. It opens no UI and has no network or app adapters.
let source = CommandLine.arguments[1]
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for name in ["invitation", "regeneration", "new-message", "zero-recipient", "thread-reply", "proposal"] {
    let data = try Data(contentsOf: URL(fileURLWithPath: source).appendingPathComponent(name + ".json"))
    let decoded = try JSONDecoder().decode(WritingInput.self, from: data)
    if name == "zero-recipient" {
        precondition(decoded.compose.recipients.isEmpty)
        precondition(decoded.compose.subject.isEmpty)
    }
    // Only the replies that name their thread carry `thread_id`; the others
    // leave it out, and encoding leaves it out again.
    precondition((decoded.compose.threadID != nil) == (name == "thread-reply" || name == "proposal"))
    // Only the proposal carries `proposal`, and only it encodes the key; every
    // other input encodes exactly as it did before the field existed.
    precondition(decoded.compose.proposal == (name == "proposal"))
    let encoded = try decoded.encoded()
    let again = try JSONDecoder().decode(WritingInput.self, from: encoded)
    precondition(Array(decoded.cue.utf8) == Array(again.cue.utf8))
    precondition(Array(decoded.compose.subject.utf8) == Array(again.compose.subject.utf8))
    precondition(decoded.compose.threadID == again.compose.threadID)
    precondition(String(decoding: encoded, as: UTF8.self).contains("\"thread_id\"") == (decoded.compose.threadID != nil))
    precondition(again.compose.proposal == decoded.compose.proposal)
    precondition(String(decoding: encoded, as: UTF8.self).contains("\"proposal\"") == decoded.compose.proposal)
    if let edited = decoded.regeneration {
        precondition(Array(edited.editedDraft.utf8) == Array(again.regeneration!.editedDraft.utf8))
    }
    try encoded.write(to: destination.appendingPathComponent(name + ".json"))
    // Closed decoding must also refuse authority-shaped additions at nested levels.
    let raw = String(decoding: encoded, as: UTF8.self)
    let unexpected = Data(("{\"account_id\":\"forged\"," + raw.dropFirst()).utf8)
    precondition((try? JSONDecoder().decode(WritingInput.self, from: unexpected)) == nil)
    let nested = Data(raw.replacingOccurrences(
        of: "\"compose\":{", with: "\"compose\":{\"qualification\":true,"
    ).utf8)
    precondition((try? JSONDecoder().decode(WritingInput.self, from: nested)) == nil)
}
// A present flag must be a boolean. Only an absent key defaults to false.
let proposalData = try Data(contentsOf:
    URL(fileURLWithPath: source).appendingPathComponent("proposal.json"))
let proposalInput = try JSONDecoder().decode(WritingInput.self, from: proposalData)
let proposalJSON = String(decoding: try proposalInput.encoded(), as: UTF8.self)
precondition(proposalJSON.contains("\"proposal\":true,"))
let flagCases: [(String?, Bool?)] = [
    (nil, false), ("false", false), ("true", true),
    ("null", nil), ("\"true\"", nil), ("1", nil)
]
for (flag, expected) in flagCases {
    let field = flag.map { "\"proposal\":\($0)," } ?? ""
    let raw = proposalJSON.replacingOccurrences(of: "\"proposal\":true,", with: field)
    let decoded = try? JSONDecoder().decode(WritingInput.self, from: Data(raw.utf8))
    if let expected {
        precondition(decoded?.compose.proposal == expected)
    } else {
        precondition(decoded == nil)
    }
}
print("Swift writing input encoding and closed decoding passed, including six strict proposal flag cases.")

for name in ["post-x-new", "post-x-reply", "post-x-quote", "post-linkedin-post", "post-linkedin-comment"] {
    let data = try Data(contentsOf: URL(fileURLWithPath: source).appendingPathComponent(name + ".json"))
    let decoded = try JSONDecoder().decode(WritingPostInput.self, from: data)
    let encoded = try decoded.encoded()
    let again = try JSONDecoder().decode(WritingPostInput.self, from: encoded)
    precondition(Array(decoded.compose.currentText.utf8) == Array(again.compose.currentText.utf8))
    precondition(decoded.compose.selection.location == again.compose.selection.location)
    precondition(decoded.compose.selection.length == again.compose.selection.length)
    precondition(decoded.parentText.map { Array($0.utf8) } == again.parentText.map { Array($0.utf8) })
    precondition((try? JSONDecoder().decode(WritingInput.self, from: encoded)) == nil)
    let raw = String(decoding: encoded, as: UTF8.self)
    for addition in ["\"recipients\":[],", "\"proposal\":false,", "\"thread_id\":null,"] {
        let invalid = raw.replacingOccurrences(of: "\"compose\":{", with: "\"compose\":{" + addition)
        precondition((try? JSONDecoder().decode(WritingPostInput.self, from: Data(invalid.utf8))) == nil)
    }
    try encoded.write(to: destination.appendingPathComponent(name + ".json"))
}
print("Swift post input encoding passed for five kinds.")
