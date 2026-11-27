import Foundation
import CryptoKit

/// Optional 4-digit PINs on profiles (kept on this device, in the Keychain), and the
/// kids' limits each Jellyfin user has on the server (Dashboard → Users → Parental control).
enum ProfileLock {
    private static func keychainKey(_ account: String) -> String { "pin.\(account)" }

    private static func hash(_ pin: String, _ account: String) -> Data {
        Data(SHA256.hash(data: Data("huefin|\(account)|\(pin)".utf8)))
    }

    static func hasPIN(_ account: String) -> Bool { Keychain.load(keychainKey(account)) != nil }

    static func setPIN(_ pin: String, for account: String) {
        Keychain.save(hash(pin, account), key: keychainKey(account))
    }

    static func removePIN(for account: String) { Keychain.delete(keychainKey(account)) }

    static func check(_ pin: String, for account: String) -> Bool {
        guard let stored = Keychain.load(keychainKey(account)) else { return true }
        return stored == hash(pin, account)
    }

    // MARK: Kids' limits (enforced by the server; shown here so you know which profile is which)

    private static func limitKey(_ account: String) -> String { "huefin.kidsLimit.\(account)" }

    /// The highest rating this profile may watch ("PG-13"), or nil when unrestricted / not known yet.
    static func limitLabel(_ account: String) -> String? { UserDefaults.standard.string(forKey: limitKey(account)) }

    /// Jellyfin's rating scale, turned into the familiar names.
    static func label(forScore score: Int) -> String {
        switch score {
        case ..<1: return "G · TV-Y"
        case ..<8: return "TV-Y7"
        case ..<11: return "PG"
        case ..<14: return "PG-13"
        case ..<15: return "TV-14"
        case ..<18: return "R · TV-MA"
        default: return "NC-17"
        }
    }

    private struct Me: Decodable {
        struct Policy: Decodable { let maxParentalRating: Int?; let isAdministrator: Bool? }
        let policy: Policy?
    }

    /// Asks the server what this user may watch and remembers it for the profile picker.
    static func refreshLimit(client: JellyfinClient, account: String) async {
        guard let me: Me = try? await client.get("Users/Me") else { return }
        if let max = me.policy?.maxParentalRating, me.policy?.isAdministrator != true {
            UserDefaults.standard.set(label(forScore: max), forKey: limitKey(account))
        } else {
            UserDefaults.standard.removeObject(forKey: limitKey(account))
        }
    }
}
