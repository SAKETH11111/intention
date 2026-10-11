import Foundation

extension AlphaClient {
    /// One incoming message selected from the signed-in person's imported mail.
    /// Kept only for the setup page and its draft request, never logged.
    struct ReplyThread: Decodable, Sendable, Equatable {
        let id: String
        let senderName: String
        let senderAddress: String
        let subject: String
        let message: String
        let sentAt: Date

        enum CodingKeys: String, CodingKey {
            case id = "thread_id"
            case senderName = "sender_name"
            case senderAddress = "sender_address"
            case subject, message
            case sentAt = "sent_at"
        }
    }

    struct SetupReplyAnswer: Decodable, Sendable {
        enum Reason: String, Decodable, Sendable { case noMail = "no_mail", preparing, noCandidate = "no_candidate" }
        let thread: ReplyThread?
        let reason: Reason?
    }

    /// Uses the same authenticated transport as mail progress. The deadline
    /// also covers a transport that never returns its response headers.
    func setupReplyThread(deviceKey: String, timeout: Duration = .seconds(5)) async throws -> SetupReplyAnswer {
        var request = URLRequest(url: endpoint.appending(path: "v1/setup/reply-thread"))
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")
        let requestToSend = request
        return try await withThrowingTaskGroup(of: SetupReplyAnswer.self) { group in
            group.addTask {
                let (data, response) = try await perform(requestToSend, timeout: 5)
                guard response.statusCode == 200 else { throw Failure.rejected(response.statusCode) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let value = try decoder.singleValueContainer().decode(String.self)
                    let fractional = ISO8601DateFormatter()
                    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                        throw Failure.invalidResponse
                    }
                    return date
                }
                return try decoder.decode(SetupReplyAnswer.self, from: data)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let answer = try await group.next() else { throw Failure.invalidResponse }
            return answer
        }
    }
}
