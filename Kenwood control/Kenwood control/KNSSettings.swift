import Foundation

enum KNSSettings {
    // Keep keys stable; users rely on persistent login across builds.
    static let lastHostKey = "KNS.LastHost"
    static let lastPortKey = "KNS.LastPort"
    static let useLoginKey = "KNS.UseLogin"
    static let accountTypeKey = "KNS.AccountType" // "0" admin, "1" user

    static func usernameKey(host: String, accountTypeRaw: String) -> String {
        "KNS.Username.\(accountTypeRaw).\(host)"
    }

    static func keychainService(host: String, accountTypeRaw: String) -> String {
        "KenwoodControl.KNS.Password.\(accountTypeRaw).\(host)"
    }

    static func loadLastHost() -> String? { UserDefaults.standard.string(forKey: lastHostKey) }
    static func loadLastPort() -> Int? {
        guard UserDefaults.standard.object(forKey: lastPortKey) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: lastPortKey)
    }

    static func saveLastConnection(host: String, port: Int) {
        UserDefaults.standard.set(host, forKey: lastHostKey)
        UserDefaults.standard.set(port, forKey: lastPortKey)
    }

    static func loadUseLogin() -> Bool? {
        guard UserDefaults.standard.object(forKey: useLoginKey) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: useLoginKey)
    }

    static func saveUseLogin(_ use: Bool) { UserDefaults.standard.set(use, forKey: useLoginKey) }

    static func loadAccountTypeRaw() -> String? { UserDefaults.standard.string(forKey: accountTypeKey) }
    static func saveAccountTypeRaw(_ raw: String) { UserDefaults.standard.set(raw, forKey: accountTypeKey) }

    static func loadUsername(host: String, accountTypeRaw: String) -> String? {
        UserDefaults.standard.string(forKey: usernameKey(host: host, accountTypeRaw: accountTypeRaw))
    }

    static func saveUsername(_ username: String, host: String, accountTypeRaw: String) {
        UserDefaults.standard.set(username, forKey: usernameKey(host: host, accountTypeRaw: accountTypeRaw))
    }

    static func loadPassword(host: String, accountTypeRaw: String, username: String) -> String? {
        do {
            return try KeychainStore.getPassword(service: keychainService(host: host, accountTypeRaw: accountTypeRaw), account: username)
        } catch {
            AppLogger.error("Keychain read failed: \(error.localizedDescription)")
            AppFileLogger.shared.log("Keychain read failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func savePassword(_ password: String, host: String, accountTypeRaw: String, username: String) {
        do {
            try KeychainStore.setPassword(password, service: keychainService(host: host, accountTypeRaw: accountTypeRaw), account: username)
        } catch {
            AppLogger.error("Keychain write failed: \(error.localizedDescription)")
            AppFileLogger.shared.log("Keychain write failed: \(error.localizedDescription)")
        }
    }
}

