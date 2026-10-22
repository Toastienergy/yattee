//
//  TypeTypeCredentialsManager.swift
//  Yattee
//
//  Manages TypeType access tokens stored securely in the Keychain.
//
//  TypeType answers every extraction and playback request with 401 unless the
//  caller is signed in, so unlike Invidious/Piped the token is not only needed
//  for account features — it authenticates ordinary search and playback too.
//  Tokens are therefore stored twice: account-keyed (the multi-login path every
//  other manager uses) and instance-keyed (what request injection reads when a
//  call arrives without account context). The instance-keyed item is written
//  and deleted alongside the account one, never on its own.
//

import Foundation
import Security

/// Manages TypeType access tokens stored securely in the Keychain.
@MainActor
@Observable
final class TypeTypeCredentialsManager: InstanceCredentialsManager {
    private static let keychainServiceName = "com.yattee.typetype"

    /// Tracks which instances have stored tokens (for reactive UI updates)
    private(set) var loggedInInstanceIDs: Set<UUID> = []

    /// Account-keyed, identity-scoped storage — the multi-login path.
    let accountCredentials: AccountKeychainCredentials

    /// Reference to settings manager for iCloud sync decisions
    weak var settingsManager: SettingsManager? {
        didSet { accountCredentials.settingsManager = settingsManager }
    }

    init(identityScope: CredentialIdentityScope? = nil) {
        accountCredentials = AccountKeychainCredentials(
            service: Self.keychainServiceName,
            credentialNoun: "token",
            identityScope: identityScope ?? CredentialIdentityScope()
        )
    }

    /// Whether credentials should sync to iCloud Keychain (when iCloud sync is enabled for instances).
    private var shouldSyncToiCloud: Bool {
        settingsManager?.iCloudSyncEnabled == true && settingsManager?.syncInstances == true
    }

    // MARK: - InstanceCredentialsManager Protocol

    /// Stores the access token for a TypeType instance (instance-keyed item).
    func setCredential(_ credential: String, for instance: Instance) {
        storeInstanceKeyedToken(credential, instanceID: instance.id)
    }

    /// Retrieves the access token used to authenticate API calls for an instance.
    func credential(for instance: Instance) -> String? {
        readInstanceKeyedToken(instanceID: instance.id)
    }

    /// Deletes the stored token for an instance (logout).
    func deleteCredential(for instance: Instance) {
        deleteInstanceKeyedToken(instanceID: instance.id)
        loggedInInstanceIDs.remove(instance.id)
        HomeInstanceCache.shared.clear(instanceID: instance.id, contentType: .feed)
    }

    /// Checks if an instance has a stored token.
    func isLoggedIn(for instance: Instance) -> Bool {
        if loggedInInstanceIDs.contains(instance.id) {
            return true
        }
        let hasToken = credential(for: instance) != nil
        if hasToken {
            loggedInInstanceIDs.insert(instance.id)
        }
        return hasToken
    }

    /// Refreshes the logged-in status for an instance.
    func refreshLoginStatus(for instance: Instance) {
        if credential(for: instance) != nil {
            loggedInInstanceIDs.insert(instance.id)
        } else {
            loggedInInstanceIDs.remove(instance.id)
        }
    }

    // MARK: - Instance-keyed item

    private func storeInstanceKeyedToken(_ token: String, instanceID: UUID) {
        guard let data = token.data(using: .utf8) else {
            LoggingService.shared.error("Failed to encode token data", category: .keychain)
            return
        }

        let account = instanceID.uuidString
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: shouldSyncToiCloud,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            LoggingService.shared.info(
                "Stored token for TypeType instance",
                category: .keychain,
                details: "instanceID=\(instanceID)"
            )
            loggedInInstanceIDs.insert(instanceID)
        } else {
            LoggingService.shared.error(
                "Failed to store token for TypeType instance",
                category: .keychain,
                details: "instanceID=\(instanceID), status=\(status)"
            )
        }
    }

    private func readInstanceKeyedToken(instanceID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainServiceName,
            kSecAttrAccount as String: instanceID.uuidString,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    private func deleteInstanceKeyedToken(instanceID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainServiceName,
            kSecAttrAccount as String: instanceID.uuidString,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - AccountCredentialsManager

extension TypeTypeCredentialsManager: AccountCredentialsManager {
    var isScopeResolved: Bool { accountCredentials.isScopeResolved }

    /// Stores the token account-keyed and mirrors it instance-keyed: API calls
    /// that arrive without account context (search, playback) authenticate with
    /// the mirror.
    func setCredential(_ credential: String, for account: Account) {
        accountCredentials.setCredential(credential, for: account)
        storeInstanceKeyedToken(credential, instanceID: account.instanceID)
    }

    func credential(for account: Account) -> String? {
        accountCredentials.credential(for: account)
    }

    /// Deletes both the account-keyed item and the instance-keyed mirror.
    func deleteCredential(for account: Account) {
        accountCredentials.deleteCredential(for: account)
        deleteInstanceKeyedToken(instanceID: account.instanceID)
        loggedInInstanceIDs.remove(account.instanceID)
    }

    func deleteCredential(forAccountID accountID: UUID) {
        accountCredentials.deleteCredential(forAccountID: accountID)
    }

    func resyncCredentialsWithCurrentSetting() {
        accountCredentials.resyncCredentialsWithCurrentSetting()
    }

    func setUsername(_ username: String, for account: Account) {
        accountCredentials.setUsername(username, for: account)
    }

    func username(for account: Account) -> String? {
        accountCredentials.username(for: account)
    }

    func isLoggedIn(for account: Account) -> Bool {
        accountCredentials.isLoggedIn(for: account)
    }

    func refreshLoginStatus(for account: Account) {
        accountCredentials.refreshLoginStatus(for: account)
    }

    @discardableResult
    func migrateCredential(forAccountID accountID: UUID, fromScope sourceScope: String) -> Bool {
        accountCredentials.migrateCredential(forAccountID: accountID, fromScope: sourceScope)
    }

    @discardableResult
    func deleteCredential(forAccountID accountID: UUID, inScope scope: String) -> Bool {
        accountCredentials.deleteCredential(forAccountID: accountID, inScope: scope)
    }

    func hasAdoptableLegacyCredential(for account: Account) -> Bool {
        accountCredentials.hasAdoptableLegacyCredential(for: account)
    }

    @discardableResult
    func adoptLegacyCredential(for account: Account) -> Bool {
        accountCredentials.adoptLegacyCredential(for: account)
    }

    func deleteLegacyCredentialIfOwned(for account: Account) {
        accountCredentials.deleteLegacyCredentialIfOwned(for: account)
    }
}
