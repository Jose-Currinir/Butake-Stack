#if DEBUG
import Foundation

/// Screenshots of the Google Cloud tool (debug builds with BUTAKE_QA_WINDOW and a separate
/// BUTAKE_STACK_HOME). gcloud is the fake of engine/src/gcp/testdata in the temporary home, with
/// its own CLOUDSDK_CONFIG and made-up accounts: nothing reaches the owner's gcloud nor Google.
///
///     BUTAKE_QA_GCP=<cuenta>          the selected account
///     BUTAKE_QA_GCP_SHEET=revoke      «Cerrar sesión…» on it
///     BUTAKE_QA_GCP_LINK=1            the link sheet of the project on screen
extension QAHooks {
    private static func gcpValue(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && env["BUTAKE_STACK_HOME"] != nil ? env[name] : nil
    }

    static var gcpLinkSheet: Bool { gcpValue("BUTAKE_QA_GCP_LINK") == "1" }

    static func gcp(_ tool: GCPTool) async {
        if let account = gcpValue("BUTAKE_QA_GCP") { tool.selection = account }
        if gcpValue("BUTAKE_QA_GCP_SHEET") == "revoke" { tool.revoking = tool.selected }
    }
}
#endif
