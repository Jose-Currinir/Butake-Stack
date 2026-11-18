import Foundation

struct MailSummary: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let from: String
    let to: String
    let subject: String
    let date: String
    let received: Int
    let size: Int
}

struct MailAttachment: Decodable, Sendable, Hashable, Identifiable {
    let index: Int
    let name: String
    let type: String
    let size: Int
    var id: Int { index }
}

struct MailMessage: Decodable, Sendable, Hashable {
    let id: String
    let from: String
    let to: String
    let cc: String
    let subject: String
    let date: String
    let received: Int
    let size: Int
    let text: String?
    let html: String?
    let attachments: [MailAttachment]
    let headers: [[String]]
    let source: String
}
