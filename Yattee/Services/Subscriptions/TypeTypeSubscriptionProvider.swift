//
//  TypeTypeSubscriptionProvider.swift
//  Yattee
//
//  TypeType subscription provider that manages subscriptions on a TypeType
//  instance. Uses in-memory cache only - does NOT persist to SwiftData to
//  avoid corrupting local subscriptions.
//

import Foundation

/// TypeType subscription provider that syncs with a TypeType instance account.
/// Subscriptions are managed on the TypeType server and kept in memory only.
@MainActor
final class TypeTypeSubscriptionProvider: SubscriptionProvider {
    // MARK: - Properties

    /// The account this provider is bound to. One provider per account, so two
    /// logins on the same instance never share a subscription cache.
    let account: Account

    private let typeTypeAPI: TypeTypeAPI
    private let credentialsManager: TypeTypeCredentialsManager
    private let accountsManager: AccountsManager

    /// In-memory cache of subscribed channel URLs (TypeType addresses channels
    /// by URL) for fast lookup.
    private var cachedChannelIDs: Set<String> = []

    /// In-memory cache of full channel data for display.
    private var cachedChannels: [Channel] = []

    /// Whether the cache has been populated from the server.
    private var cachePopulated = false

    // MARK: - Initialization

    init(
        account: Account,
        typeTypeAPI: TypeTypeAPI,
        credentialsManager: TypeTypeCredentialsManager,
        accountsManager: AccountsManager
    ) {
        self.account = account
        self.typeTypeAPI = typeTypeAPI
        self.credentialsManager = credentialsManager
        self.accountsManager = accountsManager
    }

    // MARK: - SubscriptionProvider

    func fetchSubscriptions() async throws -> [Channel] {
        let (instance, token) = try await getAuthenticatedInstance()

        let subscriptions = try await tracking(credential: token) {
            try await typeTypeAPI.subscriptions(instance: instance, credential: token)
        }

        cachedChannels = subscriptions.map { $0.toChannel() }
        cachedChannelIDs = Set(subscriptions.map(\.channelUrl))
        cachePopulated = true

        LoggingService.shared.info("Fetched \(subscriptions.count) TypeType subscriptions", category: .api)

        return cachedChannels
    }

    func subscribe(to channel: Channel) async throws {
        let (instance, token) = try await getAuthenticatedInstance()
        let channelURL = channel.id.channelID

        try await tracking(credential: token) {
            try await typeTypeAPI.subscribe(
                channelURL: channelURL,
                name: channel.name,
                avatarURL: channel.thumbnailURL?.absoluteString ?? "",
                instance: instance,
                credential: token
            )
        }

        cachedChannelIDs.insert(channelURL)
        if !cachedChannels.contains(where: { $0.id.channelID == channelURL }) {
            cachedChannels.append(channel)
        }

        LoggingService.shared.info("Subscribed to TypeType channel", category: .api)
    }

    func unsubscribe(from channelID: String) async throws {
        let (instance, token) = try await getAuthenticatedInstance()

        try await tracking(credential: token) {
            try await typeTypeAPI.unsubscribe(channelURL: channelID, instance: instance, credential: token)
        }

        cachedChannelIDs.remove(channelID)
        cachedChannels.removeAll { $0.id.channelID == channelID }

        LoggingService.shared.info("Unsubscribed from TypeType channel", category: .api)
    }

    func isSubscribed(to channelID: String) async -> Bool {
        if !cachePopulated {
            _ = try? await fetchSubscriptions()
        }
        return cachedChannelIDs.contains(channelID)
    }

    var cachedSubscriptionCount: Int? {
        cachePopulated ? cachedChannels.count : nil
    }

    /// The subscribed channels known without a network fetch.
    var cachedSubscriptions: [Channel]? {
        cachePopulated ? cachedChannels : nil
    }

    // MARK: - Helpers

    /// The instance and bearer token this account's calls run with.
    private func getAuthenticatedInstance() async throws -> (Instance, String) {
        guard let instance = accountsManager.instance(for: account) else {
            throw APIError.invalidRequest
        }
        guard let token = credentialsManager.credential(for: account)
            ?? credentialsManager.credential(for: instance) else {
            throw APIError.unauthorized
        }
        return (instance, token)
    }

    /// Records the outcome of a server call against the account — only for the
    /// secret the request actually used, so a late answer never judges a
    /// credential it did not carry.
    private func recordOutcome(_ error: Error?, credential: String) {
        guard credentialsManager.credential(for: account) == credential else { return }
        accountsManager.recordServerOutcome(error, for: account)
    }

    private func tracking<T: Sendable>(
        credential: String,
        _ work: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await work()
            recordOutcome(nil, credential: credential)
            return result
        } catch {
            recordOutcome(error, credential: credential)
            throw error
        }
    }
}
