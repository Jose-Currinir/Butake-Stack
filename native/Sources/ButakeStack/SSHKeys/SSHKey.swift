import Foundation

/// A private key imported into Stack: only its name, description, group, type and fingerprint
/// ever reach the app. Keys belong to the base: database tunnels and the Terminal share them.
struct SSHKey: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    var group: String
    var kind: String
    var fingerprint: String
    var added: Int
    var encrypted: Bool?
}
