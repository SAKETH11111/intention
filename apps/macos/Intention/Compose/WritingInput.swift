import Foundation

// Encoding types only. They neither observe a compose nor grant account or model authority.
// Server validation applies the closed schema, bounds, exclusions and independent bindings.
private struct WritingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func closedWritingContainer<K: CodingKey & CaseIterable>(
    _ decoder: Decoder, keyedBy type: K.Type
) throws -> KeyedDecodingContainer<K> {
    let raw = try decoder.container(keyedBy: WritingKey.self)
    let allowed = Set(K.allCases.map(\.stringValue))
    guard raw.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid_writing_input"))
    }
    return try decoder.container(keyedBy: type)
}

struct WritingSourceReference: Codable, Sendable, Equatable {
    let source: String
    let sourceID: String
    let revision: UUID
    let connectionID: UUID
    let connectionGeneration: UUID

    enum CodingKeys: String, CodingKey, CaseIterable {
        case source = "source"
        case sourceID = "source_id"
        case revision = "revision"
        case connectionID = "connection_id"
        case connectionGeneration = "connection_generation"
    }

    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        revision = try values.decode(UUID.self, forKey: .revision)
        connectionID = try values.decode(UUID.self, forKey: .connectionID)
        connectionGeneration = try values.decode(UUID.self, forKey: .connectionGeneration)
    }
}

struct WritingRecipient: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case to, cc, bcc }
    let address: String
    let role: Role

    enum CodingKeys: String, CodingKey, CaseIterable {
        case address = "address"
        case role = "role"
    }

    init(
        address: String,
        role: Role
    ) {
        self.address = address
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        address = try values.decode(String.self, forKey: .address)
        role = try values.decode(Role.self, forKey: .role)
    }
}

struct WritingCompose: Codable, Sendable {
    enum ObservedOrigin: String, Codable, Sendable { case unknown }
    let recipients: [WritingRecipient]
    let subject: String
    let observedThread: String
    let observedOrigin: ObservedOrigin
    let threadSources: [WritingSourceReference]
    /// The email client's id for the thread being answered, when one can be
    /// read: Gmail's thread id in hexadecimal. Encoded only when present,
    /// since a server older than this field refuses any input holding it.
    let threadID: String?
    /// True for a reply proposed when a reply opens, with nothing asked for.
    /// Encoded only when true, so every other input encodes as before this
    /// field and an older server still takes it; one that predates the field
    /// refuses a proposal.
    let proposal: Bool
    /// Omitted while off so older servers receive the same input as before.
    let addSentWithIntention: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case recipients = "recipients"
        case subject = "subject"
        case observedThread = "observed_thread"
        case observedOrigin = "observed_origin"
        case threadSources = "thread_sources"
        case threadID = "thread_id"
        case proposal = "proposal"
        case addSentWithIntention = "add_signature"
    }

    init(
        recipients: [WritingRecipient],
        subject: String,
        observedThread: String,
        observedOrigin: ObservedOrigin,
        threadSources: [WritingSourceReference],
        threadID: String? = nil,
        proposal: Bool = false,
        addSentWithIntention: Bool = false
    ) {
        self.recipients = recipients
        self.subject = subject
        self.observedThread = observedThread
        self.observedOrigin = observedOrigin
        self.threadSources = threadSources
        self.threadID = threadID
        self.proposal = proposal
        self.addSentWithIntention = addSentWithIntention
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(recipients, forKey: .recipients)
        try values.encode(subject, forKey: .subject)
        try values.encode(observedThread, forKey: .observedThread)
        try values.encode(observedOrigin, forKey: .observedOrigin)
        try values.encode(threadSources, forKey: .threadSources)
        try values.encodeIfPresent(threadID, forKey: .threadID)
        if proposal { try values.encode(true, forKey: .proposal) }
        if addSentWithIntention { try values.encode(true, forKey: .addSentWithIntention) }
    }

    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        recipients = try values.decode([WritingRecipient].self, forKey: .recipients)
        subject = try values.decode(String.self, forKey: .subject)
        observedThread = try values.decode(String.self, forKey: .observedThread)
        observedOrigin = try values.decode(ObservedOrigin.self, forKey: .observedOrigin)
        threadSources = try values.decode([WritingSourceReference].self, forKey: .threadSources)
        threadID = try values.decodeIfPresent(String.self, forKey: .threadID)
        proposal = values.contains(.proposal) ? try values.decode(Bool.self, forKey: .proposal) : false
        addSentWithIntention = values.contains(.addSentWithIntention) ? try values.decode(Bool.self, forKey: .addSentWithIntention) : false
    }
}

struct WritingRegeneration: Codable, Sendable {
    enum Origin: String, Codable, Sendable { case generated, mixed }
    let parentRequestID: UUID
    let parentRevision: Int
    let editedDraft: String
    let instruction: String
    let origin: Origin

    enum CodingKeys: String, CodingKey, CaseIterable {
        case parentRequestID = "parent_request_id"
        case parentRevision = "parent_revision"
        case editedDraft = "edited_draft"
        case instruction = "instruction"
        case origin = "origin"
    }

    init(
        parentRequestID: UUID,
        parentRevision: Int,
        editedDraft: String,
        instruction: String,
        origin: Origin
    ) {
        self.parentRequestID = parentRequestID
        self.parentRevision = parentRevision
        self.editedDraft = editedDraft
        self.instruction = instruction
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        parentRequestID = try values.decode(UUID.self, forKey: .parentRequestID)
        parentRevision = try values.decode(Int.self, forKey: .parentRevision)
        editedDraft = try values.decode(String.self, forKey: .editedDraft)
        instruction = try values.decode(String.self, forKey: .instruction)
        origin = try values.decode(Origin.self, forKey: .origin)
    }
}

struct WritingInput: Codable, Sendable {
    enum Version: Int, Codable, Sendable { case v1 = 1 }
    enum Channel: String, Codable, Sendable { case email }
    enum Mode: String, Codable, Sendable { case reply, new }
    let version: Version
    let requestID: UUID
    let revision: Int
    let channel: Channel
    let mode: Mode
    let cue: String
    let confirmedFacts: [String]
    let compose: WritingCompose
    let regeneration: WritingRegeneration?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version = "version"
        case requestID = "request_id"
        case revision = "revision"
        case channel = "channel"
        case mode = "mode"
        case cue = "cue"
        case confirmedFacts = "confirmed_facts"
        case compose = "compose"
        case regeneration = "regeneration"
    }

    init(
        version: Version,
        requestID: UUID,
        revision: Int,
        channel: Channel,
        mode: Mode,
        cue: String,
        confirmedFacts: [String],
        compose: WritingCompose,
        regeneration: WritingRegeneration?
    ) {
        self.version = version
        self.requestID = requestID
        self.revision = revision
        self.channel = channel
        self.mode = mode
        self.cue = cue
        self.confirmedFacts = confirmedFacts
        self.compose = compose
        self.regeneration = regeneration
    }

    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        version = try values.decode(Version.self, forKey: .version)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        revision = try values.decode(Int.self, forKey: .revision)
        channel = try values.decode(Channel.self, forKey: .channel)
        mode = try values.decode(Mode.self, forKey: .mode)
        cue = try values.decode(String.self, forKey: .cue)
        confirmedFacts = try values.decode([String].self, forKey: .confirmedFacts)
        compose = try values.decode(WritingCompose.self, forKey: .compose)
        regeneration = try values.decodeIfPresent(WritingRegeneration.self, forKey: .regeneration)
    }
}

extension WritingInput {
    // Exact text is encoded without Unicode normalization. Python supplies canonical
    // comparison bytes; Swift String equality is never used as a revision check.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 65_536 else {
            throw EncodingError.invalidValue("invalid_writing_input", .init(
                codingPath: [], debugDescription: "invalid_writing_input"
            ))
        }
        return data
    }
}


// Separate encoding branch keeps every existing email caller and its bytes unchanged.
struct WritingPostSurface: Codable, Sendable {
    enum Platform: String, Codable, Sendable { case x, linkedin }
    enum Kind: String, Codable, Sendable { case new, reply, quote, post, comment }
    let platform: Platform
    let postKind: Kind
    enum CodingKeys: String, CodingKey, CaseIterable {
        case platform
        case postKind = "post_kind"
    }
    init(platform: Platform, postKind: Kind) {
        self.platform = platform
        self.postKind = postKind
    }
    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        platform = try values.decode(Platform.self, forKey: .platform)
        postKind = try values.decode(Kind.self, forKey: .postKind)
        guard (platform == .x && [.new, .reply, .quote].contains(postKind)) ||
            (platform == .linkedin && [.post, .comment].contains(postKind)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid_writing_input"))
        }
    }
}

struct WritingPostSelection: Codable, Sendable {
    let location: Int
    let length: Int
    enum CodingKeys: String, CodingKey, CaseIterable { case location, length }
    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        location = try values.decode(Int.self, forKey: .location)
        length = try values.decode(Int.self, forKey: .length)
    }
}

struct WritingPostCompose: Codable, Sendable {
    let currentText: String
    let selection: WritingPostSelection
    enum CodingKeys: String, CodingKey, CaseIterable {
        case currentText = "current_text"
        case selection
    }
    init(currentText: String, selection: WritingPostSelection) {
        self.currentText = currentText
        self.selection = selection
    }
    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        currentText = try values.decode(String.self, forKey: .currentText)
        selection = try values.decode(WritingPostSelection.self, forKey: .selection)
    }
}

struct WritingPostCharacterLimit: Codable, Sendable {
    enum CountingRule: String, Codable, Sendable {
        case xWeighted = "x_weighted"
        case unicodeScalars = "unicode_scalars"
    }
    let maximum: Int
    let countingRule: CountingRule
    enum CodingKeys: String, CodingKey, CaseIterable {
        case maximum
        case countingRule = "counting_rule"
    }
    init(maximum: Int, countingRule: CountingRule) {
        self.maximum = maximum
        self.countingRule = countingRule
    }
    init(from decoder: Decoder) throws {
        let values = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        maximum = try values.decode(Int.self, forKey: .maximum)
        countingRule = try values.decode(CountingRule.self, forKey: .countingRule)
    }
}

struct WritingPostInput: Codable, Sendable {
    enum Channel: String, Codable, Sendable { case post }
    enum Kind: String, Codable, Sendable { case spoken }
    let version: WritingInput.Version
    let requestID: UUID
    let revision: Int
    let channel: Channel
    let mode: WritingInput.Mode
    let cue: String
    let confirmedFacts: [String]
    let surface: WritingPostSurface
    let compose: WritingPostCompose
    let parentText: String?
    let parentID: String?
    let observedOrigin: WritingCompose.ObservedOrigin
    let characterLimit: WritingPostCharacterLimit?
    let regeneration: WritingRegeneration?
    let kind: Kind?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, revision, channel, mode, cue, surface, compose, regeneration, kind
        case requestID = "request_id"
        case confirmedFacts = "confirmed_facts"
        case parentText = "parent_text"
        case parentID = "parent_id"
        case observedOrigin = "observed_origin"
        case characterLimit = "character_limit"
    }

    init(version: WritingInput.Version = .v1, requestID: UUID, revision: Int,
         mode: WritingInput.Mode, cue: String, confirmedFacts: [String],
         surface: WritingPostSurface, compose: WritingPostCompose, parentText: String?,
         parentID: String? = nil, characterLimit: WritingPostCharacterLimit? = nil,
         regeneration: WritingRegeneration? = nil) {
        self.version = version
        self.requestID = requestID
        self.revision = revision
        self.channel = .post
        self.mode = mode
        self.cue = cue
        self.confirmedFacts = confirmedFacts
        self.surface = surface
        self.compose = compose
        self.parentText = parentText
        self.parentID = parentID
        self.observedOrigin = .unknown
        self.characterLimit = characterLimit
        self.regeneration = regeneration
        self.kind = nil
    }

    init(from decoder: Decoder) throws {
        let v = try closedWritingContainer(decoder, keyedBy: CodingKeys.self)
        version = try v.decode(WritingInput.Version.self, forKey: .version)
        requestID = try v.decode(UUID.self, forKey: .requestID)
        revision = try v.decode(Int.self, forKey: .revision)
        channel = try v.decode(Channel.self, forKey: .channel)
        mode = try v.decode(WritingInput.Mode.self, forKey: .mode)
        cue = try v.decode(String.self, forKey: .cue)
        confirmedFacts = try v.decode([String].self, forKey: .confirmedFacts)
        surface = try v.decode(WritingPostSurface.self, forKey: .surface)
        compose = try v.decode(WritingPostCompose.self, forKey: .compose)
        parentText = try v.decode(String?.self, forKey: .parentText)
        parentID = try v.decodeIfPresent(String.self, forKey: .parentID)
        observedOrigin = try v.decode(WritingCompose.ObservedOrigin.self, forKey: .observedOrigin)
        characterLimit = try v.decodeIfPresent(WritingPostCharacterLimit.self, forKey: .characterLimit)
        regeneration = try v.decodeIfPresent(WritingRegeneration.self, forKey: .regeneration)
        kind = try v.decodeIfPresent(Kind.self, forKey: .kind)
    }

    func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(version, forKey: .version)
        try v.encode(requestID, forKey: .requestID)
        try v.encode(revision, forKey: .revision)
        try v.encode(channel, forKey: .channel)
        try v.encode(mode, forKey: .mode)
        try v.encode(cue, forKey: .cue)
        try v.encode(confirmedFacts, forKey: .confirmedFacts)
        try v.encode(surface, forKey: .surface)
        try v.encode(compose, forKey: .compose)
        try v.encode(parentText, forKey: .parentText)
        try v.encode(parentID, forKey: .parentID)
        try v.encode(observedOrigin, forKey: .observedOrigin)
        try v.encode(characterLimit, forKey: .characterLimit)
        try v.encode(regeneration, forKey: .regeneration)
        try v.encodeIfPresent(kind, forKey: .kind)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 65_536 else {
            throw EncodingError.invalidValue("invalid_writing_input", .init(
                codingPath: [], debugDescription: "invalid_writing_input"))
        }
        return data
    }
}
