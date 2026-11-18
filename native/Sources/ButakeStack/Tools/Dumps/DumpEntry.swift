import Foundation

struct DumpEntry: Decodable, Sendable, Hashable, Identifiable {
    struct Source: Decodable, Sendable, Hashable { let name: String; let file: String; let line: Int }
    let id: Int
    let lines: [String]
    let time: Double?
    let source: Source?
    let origin: String?
}
