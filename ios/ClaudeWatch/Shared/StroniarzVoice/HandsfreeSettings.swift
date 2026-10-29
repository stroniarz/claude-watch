import Foundation
import Security

/// Minimal Keychain wrapper for a single generic-password item.
///
/// Accessibility is `AfterFirstUnlockThisDeviceOnly`: the intents run from the
/// lock screen, where `WhenUnlocked` items are unreadable.
struct KeychainStore {
    let service: String
    let account: String

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { $1 }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Where the handsfree API lives and how to authenticate.
/// Base URL and flags go to UserDefaults; the token only to the Keychain.
enum HandsfreeSettings {
    static let defaultBaseURL = "https://michas-macbook-pro.tail5f86bd.ts.net:8444"

    private static let baseURLKey = "stroniarzVoice.baseURL"
    private static let thinkingCueKey = "stroniarzVoice.thinkingCue"
    private static let keychain = KeychainStore(service: "pl.stroniarz.voice", account: "handsfree-token")

    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey) }
    }

    static var baseURL: URL? {
        guard let url = URL(string: baseURLString), url.scheme?.hasPrefix("http") == true,
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static var token: String? {
        get { keychain.read().flatMap { $0.isEmpty ? nil : $0 } }
        set {
            if let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                keychain.write(value)
            } else {
                keychain.delete()
            }
        }
    }

    /// Experimental: say "Myślę" with AVSpeechSynthesizer while /ask is slow.
    static var thinkingCue: Bool {
        get { UserDefaults.standard.object(forKey: thinkingCueKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: thinkingCueKey) }
    }

    static var isConfigured: Bool { baseURL != nil && token != nil }
}
