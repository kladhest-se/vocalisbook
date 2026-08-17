import Foundation
import Security
import UIKit
import PlexKit

/// Stores the Plex token and the client identifier in the keychain.
///
/// The client identifier matters as much as the token: Plex keys the
/// authorisation off it, so regenerating it silently invalidates the token and
/// drops the user back to sign-in with no explanation. It is written once and
/// never derived from anything mutable — not the device name, not the account.
/// A class, and main-actor, because it now holds a cache.
///
/// It was a struct, which cannot mutate stored state from a `let` — and every
/// owner holds it as one. Only `AppModel` ever constructs or uses it, and that
/// is already `@MainActor`, so this changes nothing about where it runs.
@MainActor
public final class KeychainStore {
    private let service: String

    public init(service: String = "se.kladhest.vocalisbook") {
        self.service = service
    }

    public enum Key: String, Sendable {
        case plexToken = "plex.token"
        case clientIdentifier = "plex.clientIdentifier"
        case serverIdentifier = "plex.serverIdentifier"
        case serverAccessToken = "plex.serverAccessToken"
        case sectionKey = "plex.sectionKey"
    }

    /// Read values, kept after the first read.
    ///
    /// On macOS an unsigned build gets a fresh code signature every rebuild, so
    /// the keychain treats each build as a different app and asks for the login
    /// password again — once per *read*. Sign-in alone reads the token nine
    /// times, which is nine dialogs. Caching makes it one.
    ///
    /// This is memory only and dies with the process, so it changes how often
    /// the keychain is consulted, not what is stored or how.
    private var cache: [String: String] = [:]

    public func read(_ key: Key) -> String? {
        if let cached = cache[key.rawValue] { return cached }
        let value = readFromKeychain(key)
        if let value { cache[key.rawValue] = value }
        return value
    }

    private func readFromKeychain(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, for key: Key) {
        cache[key.rawValue] = value
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(base as CFDictionary)

        var insert = base
        insert[kSecValueData as String] = Data(value.utf8)
        // Available after first unlock so background sync and downloads keep
        // working with the device locked, which is most of when this app runs.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    public func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Clears the account session. Deliberately does not touch
    /// `clientIdentifier` — reusing it on the next sign-in means Plex sees the
    /// same device rather than accumulating a new authorised entry every time.
    public func signOut() {
        cache.removeAll()
        delete(.plexToken)
        delete(.serverIdentifier)
        delete(.serverAccessToken)
        delete(.sectionKey)
    }
}

public enum DeviceIdentity {
    /// Builds the identity sent on every Plex request, minting and persisting a
    /// client identifier on first launch.
    @MainActor
    public static func current(store: KeychainStore, version: String) -> PlexClientIdentity {
        let identifier: String
        if let existing = store.read(.clientIdentifier) {
            identifier = existing
        } else {
            identifier = UUID().uuidString
            store.write(identifier, for: .clientIdentifier)
        }

        let device = UIDevice.current
        return PlexClientIdentity(
            clientIdentifier: identifier,
            product: "VocalisBook",
            version: version,
            device: device.model,
            deviceName: device.name,
            platform: "iOS",
            platformVersion: device.systemVersion
        )
    }
}
