import Foundation
@testable import ButakeStack

/// A made-up keys backup with the shape of a real one (P-33), built with the system's tools in a
/// temporary folder: an Android keystore (keytool, when a JDK is found), a self-signed «Apple
/// Distribution» certificate and its `.p12` (openssl), CMS-signed profiles that include it (and one that
/// includes another certificate), a `.p8`, Firebase and service-account JSON, history, archives, a dump
/// and a `.env`. Every password and value is a sentinel that must never show anywhere.
struct VaultBackupFixture {
    static let p12Password = "CENTINELA-P12-7f3a9c"
    static let storePassword = "CENTINELA-KS-91c2e4"
    static let issuerId = "CENTINELA-ISSUER-55d0"
    static let firebaseAppId = "1:123456789:android:c3n71n3l4f1r3b45e"
    static let envValue = "CENTINELA-ENV-0b1d"
    static var sentinels: [String] { [p12Password, storePassword, issuerId, "c3n71n3l4f1r3b45e", envValue] }
    static let app = "Demo Salud (cl.demo.health)"

    let root: URL
    /// The keystore was made (a JDK was found).
    let hasKeystore: Bool
    var appFolder: URL { root.appendingPathComponent(Self.app) }

    static let googleServices = """
    {"project_info": {"project_number": "123456789", "project_id": "demo-salud"},
     "client": [{"client_info": {"android_client_info": {"package_name": "%@"}}}]}
    """
    static let serviceAccount = """
    {"type": "service_account", "project_id": "demo-salud", "private_key_id": "0123456789abcdef0123",
     "private_key": "-----BEGIN PRIVATE KEY-----\\nNO-ES-REAL\\n-----END PRIVATE KEY-----\\n",
     "client_email": "play@demo-salud.iam.gserviceaccount.com"}
    """

    /// Nil when openssl is not there.
    static func make() throws -> VaultBackupFixture? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("respaldo-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent(".trabajo", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let openssl = "/usr/bin/openssl"
        for (name, subject) in [("dist", "Apple Distribution: Demo SpA (ABCDE12345)"), ("otro", "Apple Distribution: Otra SpA (ZZZZZ99999)")] {
            guard run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(name).key", "-out", "\(name).pem", "-days", "400",
                                "-subj", "/CN=\(subject)/OU=ABCDE12345"], in: work),
                  run(openssl, ["x509", "-in", "\(name).pem", "-outform", "DER", "-out", "\(name).der"], in: work) else { return nil }
        }
        guard run(openssl, ["pkcs12", "-export", "-inkey", "dist.key", "-in", "dist.pem", "-out", "dist.p12", "-passout", "pass:\(p12Password)"], in: work) else { return nil }
        let app = root.appendingPathComponent(Self.app)
        func folder(_ path: String) throws -> URL {
            let url = path.hasPrefix("_") ? root.appendingPathComponent(path) : app.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ text: String, _ path: String) throws {
            let url = (path.hasPrefix("_") ? root : app).appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func copy(_ name: String, _ path: String) throws {
            _ = try folder((path as NSString).deletingLastPathComponent)
            try fm.copyItem(at: work.appendingPathComponent(name), to: app.appendingPathComponent(path))
        }
        // Profiles: CMS-signed plists that list the certificates they accept.
        func profile(_ name: String, bundle: String, certificates: [String], development: Bool = false) throws {
            let ders = try certificates.map { try Data(contentsOf: work.appendingPathComponent("\($0).der")) }
            var entitlements: [String: Any] = ["application-identifier": "ABCDE12345.\(bundle)", "get-task-allow": development,
                                               "aps-environment": development ? "development" : "production",
                                               "com.apple.security.application-groups": ["group.cl.demo.health"], "com.apple.developer.healthkit": true]
            if bundle.hasSuffix("watchkitapp") { entitlements["com.apple.developer.healthkit"] = nil }
            var plist: [String: Any] = ["Name": name, "TeamName": "Demo SpA", "TeamIdentifier": ["ABCDE12345"], "DeveloperCertificates": ders,
                                        "ExpirationDate": Date().addingTimeInterval(200 * 86_400), "Entitlements": entitlements]
            if development { plist["ProvisionedDevices"] = ["00008030-000000000000001E"] }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: work.appendingPathComponent("\(name).plist"))
            guard run(openssl, ["smime", "-sign", "-in", "\(name).plist", "-signer", "dist.pem", "-inkey", "dist.key", "-outform", "DER", "-nodetach", "-binary",
                                "-out", "\(name).mobileprovision"], in: work) else { throw CocoaError(.fileWriteUnknown) }
        }
        try profile("AppStore_main", bundle: "cl.demo.health", certificates: ["dist"])
        try profile("AppStore_widget", bundle: "cl.demo.health.widget", certificates: ["otro"])
        try profile("AdHoc_main", bundle: "cl.demo.health", certificates: ["dist", "otro"], development: true)
        let info: (String) throws -> String = { bundle in
            String(decoding: try PropertyListSerialization.data(fromPropertyList: ["PROJECT_ID": "demo-salud", "BUNDLE_ID": bundle, "GCM_SENDER_ID": "123456789",
                                                                                   "API_KEY": "no-se-muestra"], format: .xml, options: 0), as: UTF8.self)
        }

        // iOS, production: the certificate with its password, two profiles, the store key with its ids.
        try copy("dist.p12", "03-IOS/PROD/dist.p12")
        try write(p12Password + "\n", "03-IOS/PROD/dist.p12.pass")
        try copy("AppStore_main.mobileprovision", "03-IOS/PROD/AppStore_main.mobileprovision")
        try copy("AppStore_widget.mobileprovision", "03-IOS/PROD/AppStore_widget.mobileprovision")
        try write("-----BEGIN PRIVATE KEY-----\nNO-ES-REAL-ASC\n-----END PRIVATE KEY-----\n", "03-IOS/PROD/AuthKey_ABC123DEF4.p8")
        try write("APP_STORE_CONNECT_API_KEY_KEY_ID=ABC123DEF4\nAPP_STORE_CONNECT_API_KEY_ISSUER_ID=\(issuerId)\n", "03-IOS/PROD/fastlane.env")
        try write(try info("cl.demo.health"), "03-IOS/PROD/GoogleService-Info.plist")
        try write("-----BEGIN PRIVATE KEY-----\nNO-ES-REAL-CERT\n-----END PRIVATE KEY-----\n", "03-IOS/PROD/distribucion.key")
        // iOS, QA: the same certificate again (one copy is imported), an ad hoc profile, another app's plist.
        try copy("dist.p12", "03-IOS/QA/dist.p12")
        try write(p12Password, "03-IOS/QA/dist.p12.clave")
        try copy("AdHoc_main.mobileprovision", "03-IOS/QA/AdHoc_main.mobileprovision")
        try write(try info("cl.demo.otra"), "03-IOS/QA/GoogleService-Info.plist")
        // Android, production: keystore with its credentials («la misma»), Firebase and its App ID.
        var hasKeystore = false
        if let keytool = VaultInspector.keytool() {
            hasKeystore = run(keytool.path, ["-genkeypair", "-keystore", "upload.jks", "-storetype", "PKCS12", "-alias", "upload", "-keyalg", "RSA", "-keysize", "2048",
                                             "-validity", "9000", "-storepass", storePassword, "-keypass", storePassword, "-dname", "CN=Demo SpA, O=Demo SpA, C=CL"], in: work)
        }
        if hasKeystore { try copy("upload.jks", "04-ANDROID/PROD/upload.jks") }
        try write("# Llavero de subida\n- **Store password:** \(storePassword)\n- Alias: upload\n- Key password: la misma\n", "04-ANDROID/PROD/CREDENTIALS.txt")
        try write(String(format: googleServices, "cl.demo.health"), "04-ANDROID/PROD/google-services.json")
        try write(firebaseAppId + "\n", "04-ANDROID/PROD/FIREBASE_APP_ID.txt")
        try write(String(format: googleServices, "cl.demo.health.qa"), "04-ANDROID/QA/google-services.json")
        // Server: a .env (goes to Entornos) and a dump; history and archives.
        try write("APP_KEY=\(envValue)\n", "01-API/PROD/.env")
        try write("-- volcado\n", "01-API/PROD/base.dump")
        try copy("otro.der", "99-HISTORICO-TRANSICION/viejo.cer")
        try copy("AppStore_main.mobileprovision", "03-IOS/_archive/AppStore_2024.mobileprovision")
        // Services shared by every app.
        try write(serviceAccount, "_SERVICIOS/google-play/play-ci.json")
        try write("-----BEGIN PRIVATE KEY-----\nNO-ES-REAL-APNS\n-----END PRIVATE KEY-----\n", "_SERVICIOS/apple-apns/AuthKey_PUSH123456.p8")
        try fm.removeItem(at: work)
        return VaultBackupFixture(root: root, hasKeystore: hasKeystore)
    }

    static func run(_ path: String, _ arguments: [String], in folder: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
