import Foundation
import CryptoKit

/// Purpose: Persistent settings for Curtain, stored as JSON in Application Support.
/// Inputs: none (reads/writes ~/Library/Application Support/Curtain/config.json)
/// Outputs: a mutable singleton `Config.shared`
/// Constraints: password is stored as a salted SHA256 hash, never plaintext.
/// SPORT: MASTER-CONFIG
struct Config: Codable {
    /// Whether Curtain is armed. When false, no curtain is shown on connect.
    var enabled: Bool = true
    /// Salted SHA256 of the unlock password (hex). Empty = no password set (uses default).
    var passwordHash: String = ""
    /// Random per-install salt for the password hash.
    var salt: String = ""
    /// Serial numbers of DisplayLink monitors. They can only be hidden with a
    /// capturable cover (visible in the remote view too) — see Lessons. Native
    /// displays are hidden invisibly via sharingType=.none.
    var displayLinkSerials: [UInt32] = []
    /// Minutes of no input before the session is force-ended + the Mac locked.
    var idleMinutes: Int = 30

    private static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Curtain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static var shared: Config = load()

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            var c = Config(); c.salt = randomSalt(); c.save(); return c
        }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url) }
    }

    // MARK: - Password

    /// Set a new unlock password (stored hashed).
    mutating func setPassword(_ plain: String) {
        if salt.isEmpty { salt = Self.randomSalt() }
        passwordHash = Self.hash(plain, salt: salt)
        save()
    }

    /// Verify a candidate password against the stored hash. If no password is set,
    /// the built-in default "curtain" is accepted so the Mac is never unrecoverable.
    func verify(_ candidate: String) -> Bool {
        if passwordHash.isEmpty { return candidate == "curtain" }
        return Self.hash(candidate, salt: salt) == passwordHash
    }

    private static func randomSalt() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func hash(_ s: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + s).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
