import Foundation

enum KenwoodKNS {
    enum AccountType: String {
        case administrator = "0"
        case user = "1"
    }

    static func knsConnect() -> String {
        "##CN;"
    }

    /// Builds the LAN login frame described in the TS-890S PC CONTROL COMMAND Reference Guide.
    /// Format: ##ID + P1(account type 0/1) + P2(2-digit account length) + P3(2-digit password length) + account + password + ;
    static func knsLogin(accountType: AccountType = .administrator, account: String, password: String) -> String {
        // Kenwood specifies the "character string length" fields; for safety we treat these as byte counts.
        let accountLen = String(format: "%02d", account.utf8.count)
        let passwordLen = String(format: "%02d", password.utf8.count)
        return "##ID\(accountType.rawValue)\(accountLen)\(passwordLen)\(account)\(password);"
    }
}
