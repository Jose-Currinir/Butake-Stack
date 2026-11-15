import SwiftUI

/// The page of a tool in the sidebar (Herramientas): one route, `.tool(id)`, for every tool.
struct ToolPage: View {
    @Bindable var store: StackStore
    let id: String
    var body: some View {
        switch id {
        case "database-client": DatabaseClientView()
        case "ssh-terminal": SSHTerminalView()
        case "mail": MailPage(store: store)
        case "dumps": DumpsPage(store: store)
        case "logs": LogsPage(store: store)
        case "vault": VaultPage(store: store)
        case "aws": AWSPage(store: store)
        case "gcp": GCPPage(store: store)
        case "git": GitPage(store: store)
        default: HomePage(store: store)
        }
    }
}
