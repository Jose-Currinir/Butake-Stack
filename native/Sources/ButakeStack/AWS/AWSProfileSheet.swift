import SwiftUI

/// «Nuevo perfil…» and «Editar…»: a grouped form with the profile's name, its kind (new profiles
/// only) and the settings of that kind, then region and output. Typed access keys stay in this sheet
/// and go to the engine once, on «Crear»; with «Llavero de Stack» they never reach a file.
struct AWSProfileSheet: View {
    let tool: AWSTool
    let original: AWSProfile?
    @State private var draft: AWSDraft
    @State private var keyID = ""
    @State private var secret = ""
    @State private var keychain = false
    @State private var newSession = false

    static let outputs = ["json", "yaml", "yaml-stream", "text", "table"]
    static let newSessionTag = "\u{1}new"

    init(tool: AWSTool, original: AWSProfile?) {
        self.tool = tool
        self.original = original
        var draft = original.map(AWSDraft.init) ?? AWSDraft()
        if original == nil, let session = tool.state?.ssoSessions.first { draft.ssoSession = session.name }
        _draft = State(initialValue: draft)
        _newSession = State(initialValue: original == nil && (tool.state?.ssoSessions.isEmpty ?? true))
        #if DEBUG
        if original == nil, let preset = QAHooks.awsSheetKind { _draft = State(initialValue: { var d = draft; d.kind = preset; return d }()) }
        if original == nil, QAHooks.awsSheetKeychain { _keychain = State(initialValue: true) }
        #endif
    }

    private var isNew: Bool { original == nil }
    private var taken: Bool { draft.name != original?.name && tool.profile(draft.name) != nil }
    private var valid: Bool {
        guard AWSDraft.validName(draft.name), !taken else { return false }
        let account = draft.accountId.count == 12 && draft.accountId.allSatisfy(\.isNumber)
        switch draft.kind {
        case .static: return !isNew || (keyID.count >= 16 && secret.count >= 16)
        case .sso:
            let session = isNew ? (newSession ? AWSDraft.validName(draft.ssoSession) && draft.ssoStartUrl.hasPrefix("https://") && !draft.ssoRegion.isEmpty
                                   : !draft.ssoSession.isEmpty) : true
            return session && account && !draft.roleName.isEmpty
        case .role: return (!isNew && original?.sourceProfile == nil) || (draft.roleArn.hasPrefix("arn:aws") && !draft.sourceProfile.isEmpty)
        default: return !isNew
        }
    }

    var body: some View {
        SheetFrame(title: L(isNew ? "aws.sheet.new" : "aws.sheet.edit"), symbol: draft.kind.symbol,
                   note: draft.kind == .static && isNew ? L(keychain ? "aws.sheet.keychainNote" : "aws.sheet.fileNote") : L("aws.sheet.backupNote"),
                   width: 560, height: 560, actionTitle: L(isNew ? "common.create" : "common.save"),
                   actionID: "aws.sheet.save", canAct: valid, cancelID: "aws.sheet.cancel", action: save) {
            Form {
                Section {
                    TextField(L("aws.sheet.namePlaceholder"), text: $draft.name, prompt: Text(L("aws.sheet.namePlaceholder"))).formField(L("common.name"))
                        .accessibilityIdentifier("aws.sheet.name")
                    if taken { Text(L("error.aws_profile_exists")).font(.uiCaption).foregroundStyle(Brand.dangerText) }
                    if isNew {
                        Picker(L("aws.sheet.kind"), selection: $draft.kind) {
                            ForEach([AWSProfile.Kind.static, .sso, .role], id: \.self) { Text($0.title).tag($0) }
                        }
                        .accessibilityIdentifier("aws.sheet.kind")
                    } else {
                        InfoRow(title: L("aws.sheet.kind"), value: draft.kind.title)
                    }
                }
                kindSection
                Section(L("aws.configuration")) {
                    TextField(L("aws.sheet.regionPlaceholder"), text: $draft.region, prompt: Text(L("aws.sheet.regionPlaceholder"))).formField(L("aws.region"))
                        .accessibilityIdentifier("aws.sheet.region")
                    Picker(L("aws.output"), selection: $draft.output) {
                        Text(L("aws.outputDefault")).tag("")
                        ForEach(Self.outputs, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .accessibilityIdentifier("aws.sheet.output")
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 340)
        }
    }

    @ViewBuilder private var kindSection: some View {
        switch draft.kind {
        case .static where isNew:
            Section(L("aws.credentials")) {
                TextField(L("aws.sheet.keyIdPlaceholder"), text: $keyID, prompt: Text(L("aws.sheet.keyIdPlaceholder"))).font(.uiBody.monospaced()).formField(L("aws.credentials.keyId"))
                    .accessibilityIdentifier("aws.sheet.keyId")
                SecureField(L("aws.sheet.secretPlaceholder"), text: $secret, prompt: Text(L("aws.sheet.secretPlaceholder"))).formField(L("aws.sheet.secret"))
                    .accessibilityIdentifier("aws.sheet.secret")
                Picker(L("aws.sheet.storage"), selection: $keychain) {
                    Text(L("aws.sheet.storageFile")).tag(false)
                    Text(L("aws.sheet.storageKeychain")).tag(true)
                }
                .disabled(tool.state?.helperAvailable == false)
                .help(L("aws.sheet.storageHelp"))
                .accessibilityIdentifier("aws.sheet.storage")
            }
        case .sso:
            Section(L("aws.session")) {
                if isNew {
                    Picker(L("aws.sso.session"), selection: Binding(get: { newSession ? Self.newSessionTag : draft.ssoSession },
                                                                     set: { value in
                                                                         newSession = value == Self.newSessionTag
                                                                         draft.ssoSession = newSession ? "" : value
                                                                     })) {
                        ForEach(tool.state?.ssoSessions ?? [], id: \.name) { Text(verbatim: $0.name).tag($0.name) }
                        Text(L("aws.sheet.newSession")).tag(Self.newSessionTag)
                    }
                    .accessibilityIdentifier("aws.sheet.session")
                    if newSession {
                        TextField(L("aws.sheet.sessionNamePlaceholder"), text: $draft.ssoSession, prompt: Text(L("aws.sheet.sessionNamePlaceholder"))).formField(L("aws.sheet.sessionName"))
                            .accessibilityIdentifier("aws.sheet.sessionName")
                        TextField(L("aws.sheet.startUrlPlaceholder"), text: $draft.ssoStartUrl, prompt: Text(L("aws.sheet.startUrlPlaceholder"))).formField(L("aws.sso.startUrl"))
                            .accessibilityIdentifier("aws.sheet.startUrl")
                        TextField(L("aws.sheet.regionPlaceholder"), text: $draft.ssoRegion, prompt: Text(L("aws.sheet.regionPlaceholder"))).formField(L("aws.sheet.sessionRegion"))
                            .accessibilityIdentifier("aws.sheet.sessionRegion")
                    }
                } else {
                    InfoRow(title: L("aws.sso.session"), value: draft.ssoSession)
                }
                TextField(L("aws.sheet.accountPlaceholder"), text: $draft.accountId, prompt: Text(L("aws.sheet.accountPlaceholder"))).formField(L("aws.account"))
                    .accessibilityIdentifier("aws.sheet.account")
                TextField(L("aws.sheet.rolePlaceholder"), text: $draft.roleName, prompt: Text(L("aws.sheet.rolePlaceholder"))).formField(L("aws.sso.role"))
                    .accessibilityIdentifier("aws.sheet.role")
            }
        case .role where isNew || original?.sourceProfile != nil:
            Section(L("aws.kind.role")) {
                TextField(L("aws.sheet.arnPlaceholder"), text: $draft.roleArn, prompt: Text(L("aws.sheet.arnPlaceholder"))).formField(L("aws.role.arn"))
                    .accessibilityIdentifier("aws.sheet.arn")
                Picker(L("aws.role.source"), selection: $draft.sourceProfile) {
                    Text(L("aws.sheet.choose")).tag("")
                    ForEach(tool.profiles.filter { $0.name != original?.name }) { Text(verbatim: $0.name).tag($0.name) }
                }
                .accessibilityIdentifier("aws.sheet.source")
            }
        default:
            EmptyView()
        }
    }

    private func save() async -> Bool {
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.region = draft.region.trimmingCharacters(in: .whitespaces)
        guard let original else {
            let keys = draft.kind == .static ? (id: keyID.trimmingCharacters(in: .whitespaces), secret: secret.trimmingCharacters(in: .whitespaces)) : nil
            let done = await tool.create(draft, keys: keys, keychain: keychain)
            if done { secret = "" }
            return done
        }
        return await tool.update(original, draft)
    }
}

/// «Duplicar…» (the copy's name) and «Marcar como predeterminado…» (the name the current default
/// keeps). The CLI's default is the profile named `default`: nothing is copied, names change.
struct AWSNameSheet: View {
    enum Kind { case duplicate, makeDefault }
    let tool: AWSTool
    let kind: Kind
    let profile: AWSProfile
    @State private var name: String

    init(tool: AWSTool, kind: Kind, profile: AWSProfile) {
        self.tool = tool
        self.kind = kind
        self.profile = profile
        _name = State(initialValue: kind == .duplicate ? "\(profile.name)-copia" : "default-anterior")
    }

    /// Marking a default when there is none asks for no name.
    private var needsName: Bool { kind == .duplicate || tool.profile("default") != nil }
    private var valid: Bool { !needsName || (AWSDraft.validName(name) && tool.profile(name) == nil && name != "default") }

    var body: some View {
        SheetFrame(title: kind == .duplicate ? String(format: L("aws.duplicateTitle"), profile.name) : String(format: L("aws.makeDefaultTitle"), profile.name),
                   symbol: kind == .duplicate ? Symbols.copy : Symbols.makeDefault,
                   note: kind == .duplicate ? L("aws.duplicateNote") : L(needsName ? "aws.makeDefaultNote" : "aws.makeDefaultNoteNone"),
                   width: 460, actionTitle: L(kind == .duplicate ? "aws.duplicate" : "aws.makeDefault"),
                   actionID: "aws.name.save", canAct: valid, cancelID: "aws.name.cancel") {
            switch kind {
            case .duplicate: await tool.duplicate(profile, as: name)
            case .makeDefault: await tool.makeDefault(profile, previous: needsName ? name : nil)
            }
        } content: {
            if needsName {
                Form {
                    TextField(L("common.name"), text: $name)
                        .formField(L(kind == .duplicate ? "aws.duplicateName" : "aws.previousDefaultName"))
                        .accessibilityIdentifier("aws.name.field")
                }
                .formStyle(.grouped).themedScroll()
                .frame(minHeight: 70)
            }
        }
    }
}
