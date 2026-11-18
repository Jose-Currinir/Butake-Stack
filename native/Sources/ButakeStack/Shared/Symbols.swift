import SwiftUI

/// One SF Symbol per concept, named by what it means, not by how it looks. Views take their
/// symbols from here so a concept looks the same everywhere (see docs/estandar-ui.md, rule 11).
enum Symbols {
    // Opening things elsewhere
    /// Open a project or a link in the web browser.
    static let openInBrowser = "safari"
    /// Open in another app of the ecosystem (Butake Git).
    static let openInApp = "arrow.up.forward.app"
    static let terminal = "terminal"
    /// Open a folder in the code editor.
    static let editor = "chevron.left.forwardslash.chevron.right"
    /// Source code shown in place: DDL, syntax, code templates.
    static let code = "curlybraces"

    // Places
    /// Inicio, and a user's home folder.
    static let home = "house"
    /// The catalog of tools, where they are turned on and off.
    static let tools = "wrench.and.screwdriver"
    /// Utilidades: programs Stack installs from their makers (assistants, cloud and repository CLIs).
    static let utilities = "arrow.down.app"
    /// AI assistants: the IA work profile and its utilities.
    static let ai = "sparkles"
    /// How an assistant's session is doing: context and the plan's limits.
    static let usage = "gauge.with.needle"
    /// A remote place: a Git remote, the Google Cloud command line that is missing.
    static let cloud = "cloud.fill"
    /// Líneas de comandos de nube (Componentes › Utilidades): the providers' command lines.
    static let cloudCommands = "bolt.horizontal.icloud.fill"
    /// Lenguajes (Componentes): the languages and their versions.
    static let languages = "curlybraces.square.fill"
    /// A folder whose projects are imported together.
    static let importFolder = "folder.badge.gearshape"

    // Things
    static let folder = "folder"
    static let newFolder = "folder.badge.plus"
    /// A project of several parts (a folder marked as a project), and «Convertir en proyecto».
    static let compositeProject = "square.3.layers.3d"
    /// A part that uses another one (its port or its public address).
    static let dependency = "arrow.right.circle"
    /// Opens and closes something in place (turned a quarter while open), like a sidebar section.
    static let disclosure = "chevron.right"
    /// Plegar / Desplegar todas las carpetas.
    static let collapseAll = "rectangle.compress.vertical"
    static let expandAll = "rectangle.expand.vertical"
    /// Leads onward: a row that opens its page, the next page of a listing.
    static let forward = "chevron.right"
    static let project = "square.grid.2x2"
    /// A project's local address.
    static let address = "globe"
    static let service = "cylinder.split.1x2"
    static let database = "cylinder"
    static let server = "server.rack"
    static let key = "key"
    /// The vault and what it keeps locked.
    static let vault = "lock.shield.fill"
    /// A certificate: the local HTTPS authority that macOS trusts, a connection's TLS.
    static let certificate = "checkmark.shield.fill"
    /// Network: addresses, ports, connections and the .test domains macOS resolves to this Mac.
    static let network = "network"
    /// Iniciar con la sesión: Stack serves its ports from the moment the user logs in.
    static let startup = "person.badge.clock"
    /// A server's host key that is unknown or changed.
    static let hostKey = "key.viewfinder"
    static let settings = "gearshape"
    /// Themes and colors: Ajustes › Apariencia and the terminal's themes.
    static let appearance = "paintpalette"
    /// Ajustes › Avanzado: folders and the configuration.
    static let advanced = "gearshape.2"
    static let processes = "cpu"
    /// Language versions a project runs on.
    static let versions = "square.3.layers.3d"
    static let logs = "text.alignleft"

    // States
    static let warning = "exclamationmark.triangle.fill"
    static let error = "exclamationmark.octagon.fill"
    static let success = "checkmark.circle.fill"
    /// The chosen option in a list of choices.
    static let selected = "checkmark.circle.fill"

    // Actions
    static let add = "plus"
    /// Takes something out of a list without losing it.
    static let remove = "minus.circle"
    /// Deletes data.
    static let delete = "trash"
    static let reload = "arrow.clockwise"
    /// Downloads and installs something from its official source.
    static let install = "icloud.and.arrow.down"
    /// Starts the supervisor.
    static let start = "play"
    /// The setup assistant and what it still has to prepare.
    static let setup = "checklist.checked"
    static let copy = "doc.on.doc"
    /// Share, export and upload.
    static let share = "square.and.arrow.up"
    static let format = "text.justify.left"
    static let edit = "pencil"
    /// Stops a service or a process (Symbols.start starts it, and runs a query).
    static let stop = "stop"
    /// Installs a newer build of the same line.
    static let update = "arrow.up.to.line.circle"
    /// The version a language uses everywhere unless a project says otherwise.
    static let global = "pin"
    /// The menu of a row or a page with the rest of its actions.
    static let more = "ellipsis.circle"
    /// Leads back: the previous page of a listing.
    static let back = "chevron.left"
    static let search = "magnifyingglass"
    static let filter = "line.3.horizontal.decrease"
    static let sort = "arrow.up.and.down.text.horizontal"
    static let history = "clock.arrow.circlepath"
    static let close = "xmark"
    /// A menu of choices beside a field (common column types).
    static let dropDown = "list.bullet"
    static let info = "info.circle"
    static let file = "doc"
    static let link = "link"
    static let package = "shippingbox"
    static let port = "number"
    /// Something that is shown but can't be changed.
    static let readOnly = "lock"
    static let user = "person"
    static let users = "person.2"
    static let newUser = "person.badge.plus"
    /// A project the user marked to keep at hand in the menu bar panel.
    static let favorite = "star.fill"
    /// Opens the app's window.
    static let openWindow = "macwindow"
    /// Something checked against its signature before it is used (an update).
    static let verified = "checkmark.seal"
    /// A project whose folder is no longer where Stack expects it.
    static let missingFolder = "folder.badge.questionmark"
    /// Finds the folder of a project that was moved or renamed outside Stack.
    static let findFolder = "magnifyingglass.circle"
    /// Gives a project another title and identifier (P-41).
    static let renameProject = "character.cursor.ibeam"
    /// Points a project at another folder, without moving files (P-41).
    static let changeFolder = "folder.circle"
    /// Subfolders of the projects folder where new projects go, by kind (`ProjectPlace`).
    static let placeApp = "macbook.and.iphone"
    static let placeService = "cube.transparent"
    static let placeWeb = "globe.americas"
    /// Takes a project out of its folder (the project stays).
    static let removeFromFolder = "folder.badge.minus"
    /// Butake Git and a project's repository.
    static let git = "arrow.triangle.branch"
    /// A project's environments (`.env`) and the one in use.
    static let environments = "square.stack.3d.down.right"
    static let switchEnvironment = "arrow.left.arrow.right.circle"
    /// A project that comes in under another name because its own is taken.
    static let renamed = "arrow.triangle.swap"
    /// Brings something in from a file or a folder: a configuration, a `.env`, a backup, SSH hosts.
    static let importing = "square.and.arrow.down.on.square"
    static let save = "square.and.arrow.down"
    /// Clears a field.
    static let clear = "xmark.circle.fill"
    /// A step that has not started yet.
    static let pending = "circle"
    /// A value, a key or the vault kept locked: secret values, a key with a passphrase, locking.
    static let locked = "lock.fill"
    /// Active or ready to act by itself: the environment in use, a lifecycle that is on, a process
    /// or a forward that starts with the rest.
    static let active = "bolt.fill"

    // Appearance: the theme's modes.
    static let themeSystem = "circle.lefthalf.filled"
    static let lightMode = "sun.max"
    static let darkMode = "moon"

    // SSH terminal.
    static let newHost = "rectangle.badge.plus"
    /// Port forwards of a host.
    static let forwards = "arrow.left.arrow.right"
    /// A host reached through another one (ProxyJump).
    static let jump = "arrow.triangle.turn.up.right.diamond"
    /// Saved commands written at the prompt.
    static let snippets = "text.badge.plus"
    /// Free labels of a host, and the sheet that manages groups and labels.
    static let tags = "tag"
    /// The panel with the information of what is shown beside the detail.
    static let inspector = "sidebar.right"
    /// A new terminal beside the focused one, or under it.
    static let splitRight = "rectangle.split.2x1"
    static let splitDown = "rectangle.split.1x2"
    /// The parent folder of a remote listing.
    static let parentFolder = "arrow.up"
    /// A forward Stack starts again when it drops.
    static let keepAlive = "arrow.triangle.2.circlepath"
    /// A new key made by Stack.
    static let generateKey = "wand.and.stars"
    /// A passphrase kept in the Keychain.
    static let keychain = "key.icloud"

    // Correo, Dumps and Registros.
    /// A message of the local inbox.
    static let message = "envelope"
    /// Empties the whole inbox.
    static let emptyInbox = "xmark.bin"
    static let attachment = "paperclip"
    /// Stops a list from moving while it is read, and starts it again.
    static let pause = "pause.fill"
    /// Resumes a list that was paused.
    static let resume = "play.fill"
    /// Clears what is on screen; the log file and the data stay.
    static let clearView = "clear"
    /// The level of the lines shown (all, warnings, errors).
    static let level = "exclamationmark.bubble"
    /// The origin of a log: web server, PHP-FPM, services, projects, the vault.
    static let origin = "line.3.horizontal.decrease.circle"
    /// Follows the end of a log while it grows.
    static let follow = "arrow.down.to.line"
    /// A `dump()` call: the point of the code that sent it.
    static let debugDump = "ladybug"

    // Bóveda.
    static let unlock = "touchid"
    /// The vault opened, in its access log.
    static let unlocked = "lock.open"
    static let unlockFailed = "lock.trianglebadge.exclamationmark"
    /// «Nuevo…» of the vault: an app, a service or an item (the window's own «+» makes projects).
    static let newItem = "plus.rectangle.on.rectangle"
    /// An app of the vault, and a new one.
    static let app = "app.badge"
    /// The encrypted backup (`.butakevault`), made or read.
    static let backup = "lock.doc"
    /// Items about to expire, or already expired.
    static let expiring = "calendar.badge.exclamationmark"
    static let notes = "note.text"
    static let addFiles = "doc.badge.plus"
    static let reveal = "eye"
    static let hide = "eye.slash"
    static let startOver = "arrow.counterclockwise"
    /// The kinds of item and the filter by kind.
    static let kinds = "square.grid.3x2"
    /// A file that carries its fields with it (`<archivo>.datos.txt`).
    static let withFields = "list.bullet.rectangle"

    // Databases: the database client's own concepts.
    static let newConnection = "externaldrive.badge.plus"
    static let connect = "bolt.horizontal"
    static let disconnect = "bolt.horizontal.circle"
    /// A connection that goes through an SSH server.
    static let sshTunnel = "network.badge.shield.half.filled"
    static let table = "tablecells"
    /// A database view (a stored query), not a table.
    static let databaseView = "rectangle.dashed"
    static let newTable = "plus.rectangle"
    static let column = "character.textbox"
    static let index = "list.bullet.indent"
    static let foreignKey = "key.horizontal"
    static let redisType = "textformat.alt"
    static let explain = "chart.bar.doc.horizontal"
    static let transaction = "square.stack.3d.up"
    static let rollback = "arrow.uturn.backward.circle"
    static let newTab = "plus.square.on.square"
    static let openInSQL = "doc.plaintext"
    /// What will run, shown before it runs.
    static let review = "list.bullet.clipboard"
    /// Ends a server's process or query.
    static let kill = "xmark.octagon"
    /// Saves something to a file (a database backup, a download) and reads one back.
    static let dump = "arrow.down.doc"
    static let restore = "arrow.up.doc"
    static let importCSV = "tablecells.badge.ellipsis"
    static let diagram = "square.grid.3x3"
    static let focus = "scope"
    static let zoomOut = "minus.magnifyingglass"
    static let zoomIn = "plus.magnifyingglass"
    static let openTable = "arrow.up.forward.square"
    static let plainColumn = "smallcircle.circle"
    static let planRoot = "circle.fill"
    static let planStep = "arrow.turn.down.right"
    /// A server without the password Stack keeps for its root user.
    static let noRootPassword = "exclamationmark.shield"

    // AWS: the profiles of AWS CLI.
    /// A profile with only settings (region, output).
    static let awsProfile = "person.crop.square"
    /// «Nuevo perfil…» beside the window's own «+», which makes projects.
    static let newProfile = "person.crop.circle.badge.plus"
    /// Single sign-on: a profile that signs in through the browser, and «Iniciar sesión…».
    static let signIn = "person.badge.key"
    static let signOut = "rectangle.portrait.and.arrow.right"
    /// A role assumed from another profile.
    static let assumeRole = "person.2.badge.gearshape"
    /// Credentials an external program hands to the CLI.
    static let credentialProcess = "gearshape.arrow.triangle.2.circlepath"
    /// «Comprobar»: who a profile is for AWS.
    static let checkIdentity = "person.crop.circle.badge.checkmark"
    /// The profile the CLI uses when none is named.
    static let makeDefault = "flag"
    /// Points something broken at what is there now (a moved program).
    static let repair = "bandage"

    // Google Cloud: the accounts of gcloud and their projects.
    /// A person's Google account.
    static let googleAccount = "person.crop.circle"
    /// A service account (a program's identity, with its keys in the vault).
    static let serviceAccount = "person.text.rectangle"
    /// A Google Cloud project.
    static let gcpProject = "rectangle.3.group"
    /// The credentials page (OAuth clients and keys) of a project.
    static let oauthClients = "lock.rectangle"
    /// Firebase (its flame; the outline one is a project template's).
    static let firebase = "flame.fill"
    static let billing = "creditcard"

    // Skills: instructions for AI assistants, linked to each assistant's folder.
    /// A skill.
    static let skill = "book.closed"
    /// Every skill, whatever its group.
    static let allSkills = "books.vertical.fill"
    /// What is wrong with the skills and their links.
    static let skillsHealth = "stethoscope"
    static let duplicate = "square.on.square"
    /// Turns a skill on or off for every assistant.
    static let activate = "power"
    static let moveToGroup = "arrow.turn.down.right"
}

/// The color of each concept's tile, from the system's palette and with the associations of System
/// Settings: the same concept has the same color everywhere. Brand green is not a tile color; green
/// says only that something is running or correct, like the other state colors here.
enum TileColor {
    /// Folders of projects, in the blue of the system's folders.
    static let folder = Color.blue
    /// Projects of several parts: a folder that is a project.
    static let composite = Color.purple
    /// Network, domains and addresses.
    static let network = Color.blue
    /// Certificates, keys and what is kept locked.
    static let security = Color.indigo
    /// Terminals and shells.
    static let terminal = Color(white: 0.22)
    /// The app's own pages and utilities (General, Herramientas, starting with the session).
    static let system = Color.gray
    /// Identities of a cloud account: profiles that sign in or assume a role.
    static let identity = Color.teal
    // States.
    static let correct = Color.green
    static let warning = Color.orange
    static let error = Color.red
    /// Skills: the instructions for AI assistants.
    static let skills = Color.mint

    static func of(_ symbol: String) -> Color {
        switch symbol {
        case Symbols.folder, Symbols.newFolder, Symbols.importFolder: folder
        case Symbols.compositeProject: composite
        case Symbols.network, Symbols.address, Symbols.server, Symbols.connect, Symbols.disconnect, Symbols.newConnection,
             Symbols.forwards, Symbols.jump: network
        case Symbols.certificate, Symbols.vault, Symbols.key, Symbols.hostKey, Symbols.locked, Symbols.unlock, Symbols.backup,
             Symbols.keychain, Symbols.generateKey: security
        case Symbols.terminal: terminal
        case Symbols.skill, Symbols.allSkills: skills
        case Symbols.signIn, Symbols.assumeRole, Symbols.awsProfile, Symbols.checkIdentity, Symbols.googleAccount,
             Symbols.serviceAccount: identity
        default: system
        }
    }
}
