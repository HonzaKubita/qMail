import Foundation
import MailCore
import Security

enum AccountSecret: Codable, Sendable {
    case password(String)
    case oauth(OAuthTokens)
}

/// Stores account secrets in the Keychain and hands out fresh credentials, refreshing OAuth
/// access tokens when they are about to expire.
actor CredentialStore {
    private static let service = "com.honzakubita.qmail.accounts"
    private var cache: [UUID: AccountSecret] = [:]
    private var refreshTasks: [UUID: Task<OAuthTokens, Error>] = [:]

    func save(_ secret: AccountSecret, for accountID: UUID) throws {
        let data = try JSONEncoder().encode(secret)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw MailError.invalidConfiguration("Couldn't save the password to the Keychain (\(status)).")
        }
        cache[accountID] = secret
    }

    func secret(for accountID: UUID) -> AccountSecret? {
        if let cached = cache[accountID] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let secret = try? JSONDecoder().decode(AccountSecret.self, from: data) else { return nil }
        cache[accountID] = secret
        return secret
    }

    func delete(accountID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        cache[accountID] = nil
    }

    func auth(for account: Account, oauth: OAuthConfiguration?) async throws -> MailAuth {
        switch secret(for: account.id) {
        case .password(let password):
            return .password(username: account.username, password: password)
        case .oauth(let tokens):
            guard tokens.needsRefresh else { return .oauth2(username: account.username, accessToken: tokens.accessToken) }
            guard let oauth else {
                throw MailError.oauth("\(account.provider.displayName) sign-in isn't configured. Add a client ID in Settings ▸ Sign-In.")
            }
            let refreshed = try await refresh(tokens, accountID: account.id, config: oauth)
            return .oauth2(username: account.username, accessToken: refreshed.accessToken)
        case nil:
            throw MailError.authenticationFailed("No saved password for \(account.email). Remove and re-add the account.")
        }
    }

    /// Coalesces concurrent refreshes from the sync and interactive connections.
    private func refresh(_ tokens: OAuthTokens, accountID: UUID, config: OAuthConfiguration) async throws -> OAuthTokens {
        if let pending = refreshTasks[accountID] { return try await pending.value }
        let task = Task { try await OAuthClient.refresh(tokens, config: config) }
        refreshTasks[accountID] = task
        defer { refreshTasks[accountID] = nil }
        let refreshed = try await task.value
        try save(.oauth(refreshed), for: accountID)
        return refreshed
    }
}
