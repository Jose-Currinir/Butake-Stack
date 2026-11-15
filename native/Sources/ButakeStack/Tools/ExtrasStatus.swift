import Foundation

/// Servers inside the daemon: the mail catcher and the dump receiver.
struct ExtrasStatus: Decodable, Sendable, Hashable {
    struct Mail: Decodable, Sendable, Hashable { let enabled: Bool; let port: Int; let running: Bool; let busy: String?; let count: Int }
    struct Dumps: Decodable, Sendable, Hashable { let enabled: Bool; let port: Int; let running: Bool; let busy: String?; let last: Int }
    let mail: Mail
    let dumps: Dumps
}
