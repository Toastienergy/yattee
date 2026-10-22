//
//  TypeTypeAPI.swift
//  Yattee
//
//  TypeType API implementation for YouTube content.
//  API Documentation: https://typetype-video.github.io/Docs-TypeType/project/playback
//
//  TypeType plays YouTube VOD through its own SABR session machinery, but the
//  server also transmuxes that session into standard HLS: one GET on
//  `/api/sabr/manifest/{videoId}?format=hls` answers with a regular HLS master
//  playlist whose segments the server serves itself. That is the whole
//  playback integration — no SABR client, no MSE, just an HLS URL for the
//  platform player. Quality selection asks the same manifest endpoint for a
//  specific `videoItag`, and `audioOnly=true` gives the audio-only variant.
//
//  Note the `/api` prefix on every route: a bundled TypeType deployment serves
//  its API under `/api` and the web frontend at the root, so a bare root path
//  would fetch the SPA's HTML instead of JSON.
//

@preconcurrency import Foundation

/// TypeType API client for fetching YouTube content.
actor TypeTypeAPI: InstanceAPI {
    private let httpClient: HTTPClient

    /// Where request authentication comes from. TypeType answers extraction and
    /// playback with 401 unless the caller is signed in, so every fetch carries
    /// the bearer token when one is stored.
    private let credentialsManager: TypeTypeCredentialsManager?

    /// Search pagination tokens, keyed by `"<query>|<page>"`.
    ///
    /// TypeType paginates with opaque `nextpage` tokens while Yattee's search
    /// interface pages by number: the token for page N+1 is only known once
    /// page N has come back, so each answer stashes its token for the next
    /// page number under the same query.
    private var searchNextPages: [String: String] = [:]

    init(httpClient: HTTPClient, credentialsManager: TypeTypeCredentialsManager? = nil) {
        self.httpClient = httpClient
        self.credentialsManager = credentialsManager
    }

    // MARK: - Authentication

    /// The bearer header for a request, or nil when nothing is signed in.
    private func authHeaders(for instance: Instance) async -> [String: String]? {
        guard let token = await credentialsManager?.credential(for: instance) else { return nil }
        return ["Authorization": "Bearer \(token)"]
    }

    /// Fetches with the bearer token attached. A rejected token (401) triggers
    /// one session refresh — the refresh cookie is kept by the shared URL
    /// session — and one retry before the failure stands.
    private func fetchAuthed<T: Decodable & Sendable>(
        _ endpoint: Endpoint,
        instance: Instance,
        token: String? = nil
    ) async throws -> T {
        let headers: [String: String]?
        if let token {
            headers = ["Authorization": "Bearer \(token)"]
        } else {
            headers = await authHeaders(for: instance)
        }
        do {
            return try await httpClient.fetch(endpoint, baseURL: instance.url, customHeaders: headers)
        } catch APIError.unauthorized {
            guard let fresh = await refreshSession(instance: instance) else {
                throw APIError.unauthorized
            }
            return try await httpClient.fetch(
                endpoint,
                baseURL: instance.url,
                customHeaders: ["Authorization": "Bearer \(fresh)"]
            )
        }
    }

    /// Signs in to a TypeType instance and returns the access token.
    func login(username: String, password: String, instance: Instance) async throws -> String {
        struct LoginRequest: Encodable, Sendable {
            let identifier: String
            let password: String
        }
        let endpoint = GenericEndpoint.post(
            "/api/auth/login",
            body: LoginRequest(identifier: username, password: password)
        )
        do {
            let response: TypeTypeSessionResponse = try await httpClient.fetch(endpoint, baseURL: instance.url)
            return response.accessToken
        } catch let error as APIError {
            if case .httpError(let statusCode, _) = error, statusCode == 401 || statusCode == 403 {
                throw APIError.unauthorized
            }
            throw error
        }
    }

    /// Exchanges the refresh cookie (kept by the shared URL session since the
    /// login response) for a new access token and stores it. Returns nil when
    /// the session has expired and a fresh sign-in is needed.
    @discardableResult
    func refreshSession(instance: Instance) async -> String? {
        let endpoint = GenericEndpoint.post("/api/auth/refresh")
        do {
            let response: TypeTypeSessionResponse = try await httpClient.fetch(endpoint, baseURL: instance.url)
            await credentialsManager?.setCredential(response.accessToken, for: instance)
            return response.accessToken
        } catch {
            return nil
        }
    }

    // MARK: - Account Features

    /// One page of the account's subscription feed.
    func feed(
        instance: Instance,
        credential: String,
        limit: Int = 30,
        cursor: String? = nil
    ) async throws -> TypeTypeFeedResponse {
        var params = [
            "service": String(TypeTypeService.youtube),
            "limit": String(limit)
        ]
        if let cursor {
            params["cursor"] = cursor
        }
        let endpoint = GenericEndpoint.get("/api/subscriptions/feed", query: params)
        return try await fetchAuthed(endpoint, instance: instance, token: credential)
    }

    /// The account's subscriptions.
    func subscriptions(instance: Instance, credential: String) async throws -> [TypeTypeSubscriptionItem] {
        let endpoint = GenericEndpoint.get("/api/subscriptions")
        return try await fetchAuthed(endpoint, instance: instance, token: credential)
    }

    /// Subscribes to a channel. TypeType wants the channel's display data
    /// alongside its URL.
    func subscribe(
        channelURL: String,
        name: String,
        avatarURL: String,
        instance: Instance,
        credential: String
    ) async throws {
        struct SubscriptionCreateRequest: Encodable, Sendable {
            let channelUrl: String
            let name: String
            let avatarUrl: String
        }
        let endpoint = GenericEndpoint.post(
            "/api/subscriptions",
            body: SubscriptionCreateRequest(
                channelUrl: channelURL,
                name: name,
                avatarUrl: avatarURL
            )
        )
        let _: TypeTypeSubscriptionItem = try await fetchAuthed(endpoint, instance: instance, token: credential)
    }

    /// Unsubscribes from a channel (addressed by its channel URL).
    func unsubscribe(channelURL: String, instance: Instance, credential: String) async throws {
        let endpoint = GenericEndpoint(
            path: "/api/subscriptions",
            method: .delete,
            queryItems: [URLQueryItem(name: "url", value: channelURL)]
        )
        // Answers 204 with no body — read and discard.
        _ = try await fetchAuthedData(endpoint, instance: instance, token: credential)
    }

    /// Public playlists the account has saved to its library.
    func savedPlaylists(instance: Instance, credential: String) async throws -> [TypeTypeSavedPlaylistItem] {
        let endpoint = GenericEndpoint.get("/api/saved-playlists")
        return try await fetchAuthed(endpoint, instance: instance, token: credential)
    }

    /// Like ``fetchAuthed(endpoint:instance:token:)`` for write operations
    /// whose success has no response body to decode.
    private func fetchAuthedData(
        _ endpoint: Endpoint,
        instance: Instance,
        token: String? = nil
    ) async throws -> Data {
        let headers: [String: String]?
        if let token {
            headers = ["Authorization": "Bearer \(token)"]
        } else {
            headers = await authHeaders(for: instance)
        }
        do {
            return try await httpClient.fetchData(endpoint, baseURL: instance.url, customHeaders: headers)
        } catch APIError.unauthorized {
            guard let fresh = await refreshSession(instance: instance) else {
                throw APIError.unauthorized
            }
            return try await httpClient.fetchData(
                endpoint,
                baseURL: instance.url,
                customHeaders: ["Authorization": "Bearer \(fresh)"]
            )
        }
    }

    // MARK: - InstanceAPI

    /// TypeType exposes one discovery feed (its home page) and no separate
    /// popular endpoint — answering both tabs from it showed the same list
    /// twice. Popular stays empty rather than duplicating Trending.
    func popular(instance: Instance) async throws -> [Video] {
        []
    }

    func trending(instance: Instance) async throws -> [Video] {
        // TypeType's home page — the recommender's rows when it is installed
        // and enabled, the plain home page otherwise, never an error from the
        // endpoint itself. Anonymous access depends on the instance's guest
        // policy; without it there is no anonymous trending at all, and Home
        // is better empty than an error banner.
        do {
            let endpoint = GenericEndpoint.get("/api/recommendations/home", query: [
                "service": String(TypeTypeService.youtube),
                "limit": "30"
            ])
            let response: TypeTypeHomeResponse = try await fetchAuthed(endpoint, instance: instance)
            return response.items.map { $0.toVideo() }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .cancelled {
            throw error
        } catch {
            return []
        }
    }

    func search(query: String, instance: Instance, page: Int, filters: SearchFilters) async throws -> SearchResult {
        // TypeType's content filters are PipePipe-style composite values
        // ("|2|channels"), verified against a live instance — plain words are
        // rejected as "Unknown content filter". The default filter is
        // "|0|all", which already carries videos, channels and playlists, so
        // Yattee's "All" chip sends nothing and the other chips map onto the
        // matching server filter.
        let contentFilter: String?
        switch filters.type {
        case .all: contentFilter = nil
        case .video: contentFilter = "|1|videos"
        case .channel: contentFilter = "|2|channels"
        case .playlist: contentFilter = "|3|playlists"
        }

        let response = try await searchPage(
            query,
            contentFilter: contentFilter,
            page: page,
            instance: instance
        )

        let videos = response.items.map { $0.toVideo() }
        let channels = (response.channels ?? []).map { $0.toChannel() }
        let playlists = (response.playlists ?? []).map { $0.toPlaylist() }

        // TypeType answers videos, channels and playlists as three separate
        // lists, so the API's own ordering between the kinds is unknown —
        // present videos first, then channels, then playlists.
        var orderedItems: [OrderedSearchItem] = []
        orderedItems.append(contentsOf: videos.map { OrderedSearchItem.video($0) })
        orderedItems.append(contentsOf: channels.map { OrderedSearchItem.channel($0) })
        orderedItems.append(contentsOf: playlists.map { OrderedSearchItem.playlist($0) })

        return SearchResult(
            videos: videos,
            channels: channels,
            playlists: playlists,
            orderedItems: orderedItems,
            nextPage: response.nextpage != nil ? page + 1 : nil
        )
    }

    /// One search request with cursor bookkeeping. TypeType paginates with
    /// opaque tokens while Yattee's interface pages by number — the token for
    /// page N+1 is stashed when page N comes back, keyed by query, content
    /// kind and page so the kinds never share a cursor chain.
    private func searchPage(
        _ query: String,
        contentFilter: String?,
        page: Int,
        instance: Instance
    ) async throws -> TypeTypeSearchResponse {
        let kind = contentFilter ?? "default"
        var params = [
            "q": query,
            "service": String(TypeTypeService.youtube)
        ]
        if let contentFilter {
            params["contentFilter"] = contentFilter
        }
        if page > 1 {
            guard let token = searchNextPages["\(query)|\(kind)|\(page)"] else {
                return TypeTypeSearchResponse(
                    items: [],
                    nextpage: nil,
                    searchSuggestion: nil,
                    isCorrectedSearch: nil,
                    playlists: nil,
                    channels: nil
                )
            }
            params["nextpage"] = token
        }
        let endpoint = GenericEndpoint.get("/api/search", query: params)
        let response: TypeTypeSearchResponse = try await fetchAuthed(endpoint, instance: instance)
        if let nextpage = response.nextpage {
            searchNextPages["\(query)|\(kind)|\(page + 1)"] = nextpage
        }
        return response
    }

    func searchSuggestions(query: String, instance: Instance) async throws -> [String] {
        let endpoint = GenericEndpoint.get("/api/suggestions", query: [
            "query": query,
            "service": String(TypeTypeService.youtube)
        ])
        let response: [String] = try await fetchAuthed(endpoint, instance: instance)
        return response
    }

    func video(id: String, instance: Instance) async throws -> Video {
        let response = try await streamResponse(videoID: id, instance: instance)
        return response.toVideo(instanceURL: instance.url, videoID: id)
    }

    func channel(id: String, instance: Instance) async throws -> Channel {
        let endpoint = GenericEndpoint.get("/api/channel", query: ["url": TypeTypeURLs.channel(id)])
        let response: TypeTypeChannelResponse = try await fetchAuthed(endpoint, instance: instance)
        return response.toChannel(id: id)
    }

    func channelVideos(id: String, instance: Instance, continuation: String?) async throws -> ChannelVideosPage {
        var params = ["url": TypeTypeURLs.channel(id)]
        if let continuation {
            params["nextpage"] = continuation
        }
        let endpoint = GenericEndpoint.get("/api/channel", query: params)
        let response: TypeTypeChannelResponse = try await fetchAuthed(endpoint, instance: instance)
        return ChannelVideosPage(
            videos: response.videos.map { $0.toVideo() },
            continuation: response.nextpage
        )
    }

    func channelPlaylists(id: String, instance: Instance, continuation: String?) async throws -> ChannelPlaylistsPage {
        var params = ["url": TypeTypeURLs.channel(id)]
        if let continuation {
            params["nextpage"] = continuation
        }
        let endpoint = GenericEndpoint.get("/api/channel/playlists", query: params)
        let response: TypeTypeChannelPlaylistsResponse = try await fetchAuthed(endpoint, instance: instance)
        return ChannelPlaylistsPage(
            playlists: response.playlists.map { $0.toPlaylist() },
            continuation: response.nextpage
        )
    }

    func playlist(id: String, instance: Instance) async throws -> Playlist {
        var params = ["url": TypeTypeURLs.playlist(id)]
        let endpoint = GenericEndpoint.get("/api/playlist", query: params)
        let firstResponse: TypeTypePlaylistResponse = try await fetchAuthed(endpoint, instance: instance)

        var allVideos = firstResponse.videos
        var nextpage = firstResponse.nextpage
        var page = 1
        let maxPages = 50

        while let token = nextpage, page < maxPages {
            params["nextpage"] = token
            let nextEndpoint = GenericEndpoint.get("/api/playlist", query: params)
            let nextResponse: TypeTypePlaylistResponse = try await fetchAuthed(nextEndpoint, instance: instance)
            if nextResponse.videos.isEmpty { break }
            allVideos.append(contentsOf: nextResponse.videos)
            nextpage = nextResponse.nextpage
            page += 1
        }

        let playlistItem = firstResponse.playlist
        return Playlist(
            id: .global(playlistItem?.id ?? id),
            title: playlistItem?.title ?? "",
            author: playlistItem?.uploaderName.map { Author(id: "", name: $0) },
            videoCount: TypeTypeSentinel.count(playlistItem?.streamCount) ?? allVideos.count,
            thumbnailURL: playlistItem?.thumbnailUrl.flatMap { URL(string: $0) },
            videos: allVideos.map { $0.toVideo() }
        )
    }

    func comments(videoID: String, instance: Instance, continuation: String?) async throws -> CommentsPage {
        var params = ["url": TypeTypeURLs.watch(videoID)]
        if let continuation {
            params["nextpage"] = continuation
        }
        let endpoint = GenericEndpoint.get("/api/comments", query: params)
        let response: TypeTypeCommentsResponse = try await fetchAuthed(endpoint, instance: instance)

        if response.commentsDisabled == true {
            throw APIError.commentsDisabled
        }

        return CommentsPage(
            comments: response.comments.map { $0.toComment() },
            continuation: response.nextpage
        )
    }

    func captions(videoID: String, instance: Instance) async throws -> [Caption] {
        let endpoint = GenericEndpoint.get("/api/subtitles/youtube/\(videoID)")
        let response: [TypeTypeSubtitleItem] = try await fetchAuthed(endpoint, instance: instance)
        return response.compactMap { $0.toCaption() }
    }

    // MARK: - Streams

    /// Resolves the stream metadata for a video in one request.
    func streamResponse(videoID: String, instance: Instance) async throws -> TypeTypeStreamResponse {
        let endpoint = GenericEndpoint.get("/api/streams/youtube/sabr", query: [
            "url": TypeTypeURLs.watch(videoID)
        ])
        return try await fetchAuthed(endpoint, instance: instance)
    }

    func streams(videoID: String, instance: Instance) async throws -> [Stream] {
        let response = try await streamResponse(videoID: videoID, instance: instance)
        let streams = response.toStreams(
            instanceURL: instance.url,
            videoID: videoID,
            httpHeaders: await authHeaders(for: instance)
        )
        prewarmAudioManifest(in: streams, instance: instance)
        return streams
    }

    /// The audio-only manifest answers 422 until its SABR session is warmed,
    /// and the player's first open races that warmup — it would spin forever.
    /// One throwaway fetch at stream-resolution time creates and warms the
    /// session, so the player's open lands on a ready one.
    private func prewarmAudioManifest(in streams: [Stream], instance: Instance) {
        guard let audio = streams.first(where: { $0.isAudioOnly }),
              let components = URLComponents(url: audio.url, resolvingAgainstBaseURL: false) else { return }
        let endpoint = GenericEndpoint(path: components.path, queryItems: components.queryItems)
        let headers = audio.httpHeaders
        Task { [httpClient] in
            _ = try? await httpClient.fetchData(endpoint, baseURL: instance.url, customHeaders: headers)
        }
    }

    /// Video details, streams, and captions from a single fetch — the stream
    /// endpoint already answers with the full metadata payload.
    func videoWithStreamsAndCaptionsAndStoryboards(
        id: String,
        instance: Instance
    ) async throws -> (video: Video, streams: [Stream], captions: [Caption], storyboards: [Storyboard]) {
        let response = try await streamResponse(videoID: id, instance: instance)
        let streams = response.toStreams(
            instanceURL: instance.url,
            videoID: id,
            httpHeaders: await authHeaders(for: instance)
        )
        prewarmAudioManifest(in: streams, instance: instance)
        return (
            response.toVideo(instanceURL: instance.url, videoID: id),
            streams,
            (response.subtitles ?? []).compactMap { $0.toCaption() },
            []
        )
    }
}

// MARK: - Service IDs

/// The service IDs TypeType's extraction layer is keyed by (PipePipeExtractor's).
private enum TypeTypeService {
    static let youtube = 0
}

// MARK: - URL Building

/// TypeType addresses content by URL, while Yattee stores bare IDs — except
/// for channels, where the ID *is* the URL TypeType handed out (channel URLs
/// are not derivable from a display name or handle alone).
private enum TypeTypeURLs {
    /// The bare YouTube video ID from whatever the caller has: a clean ID or
    /// the full watch URL. TypeType's `id` fields carry the URL (`id = url` in
    /// its item mapping), so without this every downstream URL — the SABR
    /// manifest above all — gets a URL where an ID belongs.
    static func videoID(from raw: String) -> String {
        guard raw.hasPrefix("http://") || raw.hasPrefix("https://") else { return raw }
        guard let components = URLComponents(string: raw) else { return raw }
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        // youtu.be/<id>, /shorts/<id>, /embed/<id>, /live/<id>
        let segments = components.path.split(separator: "/").map(String.init)
        if let last = segments.last, !last.isEmpty, last != "watch" {
            return last
        }
        return raw
    }

    static func watch(_ videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(TypeTypeURLs.videoID(from: videoID))"
    }

    static func channel(_ id: String) -> String {
        guard id.hasPrefix("http://") || id.hasPrefix("https://") else {
            return "https://www.youtube.com/channel/\(id)"
        }
        // Channel URLs that carry a content-tab suffix (/videos, /streams, ...)
        // extract only that tab's first page — which is why channels opened
        // from subscriptions (whose stored URL has the suffix) showed few or
        // no videos while the same channel opened from a video worked fine.
        // The base URL extracts the full channel.
        var base = id
        for suffix in ["/livestreams", "/shorts", "/streams", "/videos", "/playlists", "/community", "/featured", "/about", "/live"] {
            if let range = base.range(of: "\(suffix)([?#].*)?$", options: .regularExpression) {
                base = String(base[..<range.lowerBound])
            }
        }
        return base
    }

    static func playlist(_ id: String) -> String {
        if id.hasPrefix("http://") || id.hasPrefix("https://") {
            return id
        }
        return "https://www.youtube.com/playlist?list=\(id)"
    }
}

// MARK: - Sentinels

private enum TypeTypeSentinel {
    /// A count TypeType actually has, or nil for its `-1`/missing sentinels.
    static func count(_ raw: Int64?) -> Int? {
        guard let raw, raw >= 0 else { return nil }
        return Int(raw)
    }

    /// An upload date TypeType actually has.
    ///
    /// PipePipe-style services stamp epoch **milliseconds**; accept seconds
    /// too rather than render 1970 when a field ever changes unit. A stamp of
    /// the moment the instance answered renders as "in 0 seconds" and is
    /// dropped like the missing value it really is.
    static func date(_ raw: Int64?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        let seconds = raw > 100_000_000_000 ? TimeInterval(raw) / 1000 : TimeInterval(raw)
        let date = Date(timeIntervalSince1970: seconds)
        guard !RelativeDateFormatter.isStampedNow(date) else { return nil }
        return date
    }
}

private func typetypeStripHTML(_ html: String) -> String {
    // Comment text arrives with inline markup — channel mentions are
    // `<a href="...">@Name</a>` — and escaped entities. Keep the visible text.
    var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities: [(String, String)] = [
        ("&nbsp;", " "),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&amp;", "&")
    ]
    for (entity, replacement) in entities {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }
    return text
        .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Response Models

struct TypeTypeStreamResponse: Decodable, Sendable {
    let id: String
    let title: String
    let description: String?
    let uploaderName: String?
    let uploaderUrl: String?
    let uploaderAvatarUrl: String?
    let thumbnailUrl: String?
    let duration: Int64?
    let viewCount: Int64?
    let likeCount: Int64?
    let uploadDate: String?
    let uploaded: Int64?
    let publishedAt: Int64?
    let streamType: String?
    let isLive: Bool?
    let hasLiveManifest: Bool?
    let hlsUrl: String?
    let dashMpdUrl: String?
    let videoStreams: [TypeTypeStreamItem]?
    let audioStreams: [TypeTypeAudioItem]?
    let videoOnlyStreams: [TypeTypeStreamItem]?
    let subtitles: [TypeTypeSubtitleItem]?
    let relatedStreams: [TypeTypeVideoItem]?

    nonisolated func toVideo(instanceURL: URL, videoID: String) -> Video {
        let related: [Video]? = relatedStreams?
            .prefix(12)
            .map { $0.toVideo() }

        let channelId = uploaderUrl ?? ""
        let thumbnails = Thumbnail.fallbackChain(for: thumbnailUrl.flatMap { URL(string: $0, relativeTo: instanceURL)?.absoluteURL })

        return Video(
            id: .global(TypeTypeURLs.videoID(from: videoID)),
            title: title,
            description: description.map { typetypeStripHTML($0) },
            author: Author(
                id: channelId,
                name: uploaderName ?? "",
                thumbnailURL: uploaderAvatarUrl.flatMap { URL(string: $0, relativeTo: instanceURL)?.absoluteURL }
            ),
            duration: TimeInterval(duration ?? 0),
            publishedAt: TypeTypeSentinel.date(publishedAt ?? uploaded),
            publishedText: uploadDate,
            viewCount: TypeTypeSentinel.count(viewCount),
            likeCount: TypeTypeSentinel.count(likeCount),
            thumbnails: thumbnails,
            isLive: isLive ?? false,
            isUpcoming: false,
            scheduledStartTime: nil,
            relatedVideos: related
        )
    }

    nonisolated func toStreams(instanceURL: URL, videoID: String, httpHeaders: [String: String]? = nil) -> [Stream] {
        // Live content carries a plain HLS manifest and no SABR sources.
        if isLive == true || hasLiveManifest == true {
            if let hls = resolveURL(hlsUrl, instanceURL: instanceURL) {
                return [Stream(
                    url: hls,
                    format: "hls",
                    isLive: true,
                    mimeType: "application/vnd.apple.mpegurl",
                    httpHeaders: httpHeaders
                )]
            }
        }

        // VOD: every entry is a server-built HLS manifest over the SABR
        // session — one per quality (each fixed to its `videoItag`), plus an
        // audio-only variant. The first entry keeps the server's own format
        // choice, which is the best playable pair.
        var streams: [Stream] = []

        let videoItems = ((videoStreams ?? []) + (videoOnlyStreams ?? []))
            .filter { $0.itag != nil }

        var seenQualities = Set<String>()

        if !videoItems.isEmpty {
            // The server's own format choice is the best playable pair —
            // expose it first, labelled with the highest listed quality.
            let best = videoItems.max {
                (($0.height ?? 0), ($0.fps ?? 0)) < (($1.height ?? 0), ($1.fps ?? 0))
            }
            if let best,
               let url = TypeTypeStreamResponse.manifestURL(instanceURL, videoID: videoID, query: ["format": "hls"]) {
                if let key = best.qualityKey {
                    seenQualities.insert(key)
                }
                streams.append(Stream(
                    url: url,
                    resolution: best.resolutionModel,
                    format: "hls",
                    bitrate: best.bitrate,
                    isLive: false,
                    mimeType: "application/vnd.apple.mpegurl",
                    httpHeaders: httpHeaders,
                    fps: best.fps
                ))
            }

            for item in videoItems {
                guard let itag = item.itag,
                      let key = item.qualityKey,
                      !seenQualities.contains(key),
                      let url = TypeTypeStreamResponse.manifestURL(
                          instanceURL,
                          videoID: videoID,
                          query: ["format": "hls", "videoItag": String(itag)]
                      ) else { continue }
                seenQualities.insert(key)

                streams.append(Stream(
                    url: url,
                    resolution: item.resolutionModel,
                    format: "hls",
                    videoCodec: item.codec,
                    bitrate: item.bitrate,
                    fileSize: item.contentLength,
                    isLive: false,
                    mimeType: "application/vnd.apple.mpegurl",
                    httpHeaders: httpHeaders,
                    fps: item.fps
                ))
            }
        }

        if let url = TypeTypeStreamResponse.manifestURL(
            instanceURL,
            videoID: videoID,
            query: ["format": "hls", "audioOnly": "true"]
        ) {
            streams.append(Stream(
                url: url,
                resolution: nil,
                format: "hls",
                isAudioOnly: true,
                isLive: false,
                mimeType: "application/vnd.apple.mpegurl",
                httpHeaders: httpHeaders
            ))
        }

        return streams
    }

    private nonisolated func resolveURL(_ string: String?, instanceURL: URL) -> URL? {
        guard let string else { return nil }
        return URL(string: string, relativeTo: instanceURL)?.absoluteURL
    }

    /// The playback URL for the SABR-backed HLS manifest of one video.
    nonisolated static func manifestURL(
        _ instanceURL: URL,
        videoID: String,
        query: [String: String]
    ) -> URL? {
        guard var components = URLComponents(
            url: instanceURL.appendingPathComponent("/api/sabr/manifest/\(TypeTypeURLs.videoID(from: videoID))"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }
}

struct TypeTypeStreamItem: Decodable, Sendable {
    let url: String?
    let mimeType: String?
    let format: String?
    let resolution: String?
    let bitrate: Int?
    let codec: String?
    let isVideoOnly: Bool?
    let itag: Int?
    let width: Int?
    let height: Int?
    let fps: Int?
    let contentLength: Int64?

    /// The resolution as Yattee models it, from the pixel size when present,
    /// else parsed from the `resolution` label ("1080p").
    var resolutionModel: StreamResolution? {
        if let width, let height, height > 0 {
            return StreamResolution(width: width, height: height)
        }
        if let resolution {
            return StreamResolution(heightLabel: resolution)
        }
        return nil
    }

    /// Discriminates qualities for the stream list: same height and fps means
    /// the same row to the user, whatever the codec.
    var qualityKey: String? {
        guard let height = height ?? resolutionModel?.height else { return nil }
        return "\(height)x\(fps ?? 0)"
    }
}

struct TypeTypeAudioItem: Decodable, Sendable {
    let url: String?
    let mimeType: String?
    let format: String?
    let bitrate: Int?
    let codec: String?
    let quality: String?
    let itag: Int?
    let contentLength: Int64?
    let audioTrackId: String?
    let audioTrackName: String?
    let audioLocale: String?
    let isOriginal: Bool?
}

struct TypeTypeSubtitleItem: Decodable, Sendable {
    let url: String?
    let mimeType: String?
    let languageTag: String?
    let displayLanguageName: String?
    let isAutoGenerated: Bool?

    nonisolated func toCaption() -> Caption? {
        guard let urlString = url, let captionURL = URL(string: urlString) else { return nil }
        let name = displayLanguageName ?? languageTag ?? "Unknown"
        return Caption(
            label: isAutoGenerated == true ? "\(name) (auto-generated)" : name,
            languageCode: languageTag ?? "und",
            url: captionURL
        )
    }
}

struct TypeTypeVideoItem: Decodable, Sendable {
    let id: String
    let title: String
    let url: String?
    let thumbnailUrl: String?
    let uploaderName: String?
    let uploaderUrl: String?
    let uploaderAvatarUrl: String?
    let duration: Int64?
    let viewCount: Int64?
    let uploadDate: String?
    let uploaded: Int64?
    let publishedAt: Int64?
    let streamType: String?
    let isLive: Bool?
    let isShortFormContent: Bool?
    let uploaderVerified: Bool?
    let shortDescription: String?

    nonisolated func toVideo() -> Video {
        Video(
            id: .global(TypeTypeURLs.videoID(from: id)),
            title: title,
            description: shortDescription,
            author: Author(
                id: uploaderUrl ?? "",
                name: uploaderName ?? "",
                thumbnailURL: uploaderAvatarUrl.flatMap { URL(string: $0) },
                hasRealChannelInfo: uploaderName != nil
            ),
            duration: TimeInterval(duration ?? 0),
            publishedAt: TypeTypeSentinel.date(publishedAt ?? uploaded),
            publishedText: uploadDate,
            viewCount: TypeTypeSentinel.count(viewCount),
            likeCount: nil,
            thumbnails: Thumbnail.fallbackChain(for: thumbnailUrl.flatMap { URL(string: $0) }),
            isLive: isLive ?? false,
            isUpcoming: false,
            scheduledStartTime: nil,
            isShort: isShortFormContent
        )
    }
}

struct TypeTypeChannelResultItem: Decodable, Sendable {
    let id: String?
    let name: String?
    let url: String?
    let thumbnailUrl: String?
    let description: String?
    let subscriberCount: Int64?
    let streamCount: Int64?
    let isVerified: Bool?

    nonisolated func toChannel() -> Channel {
        Channel(
            id: .global(url ?? id ?? ""),
            name: name ?? "",
            description: description,
            subscriberCount: TypeTypeSentinel.count(subscriberCount),
            videoCount: TypeTypeSentinel.count(streamCount),
            thumbnailURL: thumbnailUrl.flatMap { URL(string: $0) },
            isVerified: isVerified ?? false
        )
    }
}

struct TypeTypePlaylistResultItem: Decodable, Sendable {
    let id: String?
    let title: String?
    let url: String?
    let thumbnailUrl: String?
    let uploaderName: String?
    let streamCount: Int64?
    let playlistType: String?

    nonisolated func toPlaylist() -> Playlist {
        Playlist(
            id: .global(id ?? url ?? ""),
            title: title ?? "",
            author: uploaderName.map { Author(id: "", name: $0) },
            videoCount: TypeTypeSentinel.count(streamCount) ?? 0,
            thumbnailURL: thumbnailUrl.flatMap { URL(string: $0) }
        )
    }
}

struct TypeTypeSearchResponse: Decodable, Sendable {
    let items: [TypeTypeVideoItem]
    let nextpage: String?
    let searchSuggestion: String?
    let isCorrectedSearch: Bool?
    let playlists: [TypeTypePlaylistResultItem]?
    let channels: [TypeTypeChannelResultItem]?
}

struct TypeTypeHomeResponse: Decodable, Sendable {
    let items: [TypeTypeVideoItem]
    let hasMore: Bool?
    let nextCursor: String?
}

struct TypeTypeChannelResponse: Decodable, Sendable {
    let name: String?
    let description: String?
    let avatarUrl: String?
    let bannerUrl: String?
    let subscriberCount: Int64?
    let isVerified: Bool?
    let videos: [TypeTypeVideoItem]
    let nextpage: String?

    nonisolated func toChannel(id: String) -> Channel {
        Channel(
            id: .global(id),
            name: name ?? "",
            description: description,
            subscriberCount: TypeTypeSentinel.count(subscriberCount),
            thumbnailURL: avatarUrl.flatMap { URL(string: $0) },
            bannerURL: bannerUrl.flatMap { URL(string: $0) },
            isVerified: isVerified ?? false
        )
    }
}

struct TypeTypeChannelPlaylistsResponse: Decodable, Sendable {
    let playlists: [TypeTypePlaylistResultItem]
    let nextpage: String?
}

struct TypeTypePlaylistResponse: Decodable, Sendable {
    let playlist: TypeTypePlaylistResultItem?
    let videos: [TypeTypeVideoItem]
    let nextpage: String?
}

struct TypeTypeCommentsResponse: Decodable, Sendable {
    let comments: [TypeTypeCommentItem]
    let nextpage: String?
    let commentsDisabled: Bool?
}

struct TypeTypeCommentItem: Decodable, Sendable {
    let id: String?
    let text: String?
    let author: String?
    let authorUrl: String?
    let authorAvatarUrl: String?
    let likeCount: Int64?
    let textualLikeCount: String?
    let publishedTime: String?
    let publishedAt: Int64?
    let isHeartedByUploader: Bool?
    let isPinned: Bool?
    let uploaderVerified: Bool?
    let replyCount: Int?
    let repliesPage: String?

    nonisolated func toComment() -> Comment {
        Comment(
            id: id ?? "",
            author: Author(
                id: authorUrl ?? "",
                name: author ?? "",
                thumbnailURL: authorAvatarUrl.flatMap { URL(string: $0) }
            ),
            content: typetypeStripHTML(text ?? ""),
            publishedAt: TypeTypeSentinel.date(publishedAt),
            publishedText: publishedTime,
            likeCount: TypeTypeSentinel.count(likeCount),
            isPinned: isPinned ?? false,
            isCreatorComment: false,
            hasCreatorHeart: isHeartedByUploader ?? false,
            replyCount: replyCount ?? 0,
            repliesContinuation: repliesPage
        )
    }
}


// MARK: - Auth & Account Models

struct TypeTypeSessionResponse: Decodable, Sendable {
    let accessToken: String
}

struct TypeTypeFeedResponse: Decodable, Sendable {
    let videos: [TypeTypeVideoItem]
    let nextpage: String?
    let generation: Int64?
    let generatedAt: Int64?
    let refreshing: Bool?
}

struct TypeTypeSubscriptionItem: Decodable, Sendable {
    let channelUrl: String
    let name: String?
    let avatarUrl: String?
    let subscribedAt: Int64?

    nonisolated func toChannel() -> Channel {
        Channel(
            id: .global(channelUrl),
            name: name ?? "",
            thumbnailURL: avatarUrl.flatMap { URL(string: $0) }
        )
    }
}

struct TypeTypeSavedPlaylistItem: Decodable, Sendable {
    let id: String?
    let publicPlaylistId: String?
    let url: String?
    let title: String?
    let thumbnailUrl: String?
    let uploaderName: String?
    let streamCount: Int64?
    let playlistType: String?
    let savedAt: Int64?

    nonisolated func toPlaylist() -> Playlist {
        Playlist(
            id: .global(publicPlaylistId ?? url ?? id ?? ""),
            title: title ?? "",
            author: uploaderName.map { Author(id: "", name: $0) },
            videoCount: TypeTypeSentinel.count(streamCount) ?? 0,
            thumbnailURL: thumbnailUrl.flatMap { URL(string: $0) }
        )
    }
}
