//
//  TypeTypeAPITests.swift
//  YatteeTests
//
//  TypeType's stream answer is the contract the HLS playback path rests on:
//  VOD is SABR behind the scenes and only becomes playable through the
//  server's `/sabr/manifest/{id}?format=hls` transcoder, so the streams this
//  client builds must point exactly there. These tests pin that mapping.
//

import Testing
import Foundation
@testable import Yattee

private let typeTypeBaseURL = URL(string: "https://tt.example.com")!

@Suite("TypeType Stream Mapping")
struct TypeTypeStreamMappingTests {
    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try HTTPClient.makeAPIDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func query(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("VOD streams are instance-served HLS manifests")
    func vodStreamsAreHLSManifests() throws {
        let response = try decode(TypeTypeStreamResponse.self, from: Self.vodJSON)
        let streams = response.toStreams(instanceURL: typeTypeBaseURL, videoID: "dQw4w9WgXcQ")

        // Best pick first, one fixed-quality entry per remaining quality, and
        // the audio-only variant.
        #expect(streams.count == 3)

        let best = try #require(streams.first)
        #expect(best.url.path == "/sabr/manifest/dQw4w9WgXcQ")
        #expect(best.url.host == "tt.example.com")
        #expect(best.format == "hls")
        #expect(!best.isAudioOnly)
        #expect(best.resolution?.height == 1080)
        #expect(query(of: best.url)["format"] == "hls")
        #expect(query(of: best.url)["videoItag"] == nil)

        let fixed = streams[1]
        #expect(fixed.resolution?.height == 720)
        #expect(query(of: fixed.url)["videoItag"] == "247")
        #expect(query(of: fixed.url)["format"] == "hls")

        let audio = streams[2]
        #expect(audio.isAudioOnly)
        #expect(query(of: audio.url)["audioOnly"] == "true")
        #expect(query(of: audio.url)["format"] == "hls")
    }

    @Test("Live streams pass the HLS manifest through untouched")
    func liveStreamsPassThrough() throws {
        let response = try decode(TypeTypeStreamResponse.self, from: Self.liveJSON)
        let streams = response.toStreams(instanceURL: typeTypeBaseURL, videoID: "live1234567")

        let stream = try #require(streams.first)
        #expect(streams.count == 1)
        #expect(stream.isLive)
        #expect(stream.url.absoluteString == "https://manifest.example.com/hls/master.m3u8")
        #expect(stream.format == "hls")
    }

    @Test("Stream metadata carries into the video model")
    func streamResponseMapsToVideo() throws {
        let response = try decode(TypeTypeStreamResponse.self, from: Self.vodJSON)
        let video = response.toVideo(instanceURL: typeTypeBaseURL, videoID: "dQw4w9WgXcQ")

        #expect(video.id.videoID == "dQw4w9WgXcQ")
        #expect(video.title == "Test Video")
        #expect(video.description == "Intro bold text")
        #expect(video.author.id == "https://www.youtube.com/channel/UCtest")
        #expect(video.duration == 212)
        #expect(video.viewCount == 12_345)
        #expect(video.likeCount == 678)
        #expect(video.publishedAt == Date(timeIntervalSince1970: 1_609_459_200))
        #expect(video.isLive == false)
        #expect(video.relatedVideos?.isEmpty == true)
    }

    static let vodJSON = """
    {
        "id": "dQw4w9WgXcQ",
        "title": "Test Video",
        "description": "Intro <b>bold</b> text",
        "uploaderName": "Test Channel",
        "uploaderUrl": "https://www.youtube.com/channel/UCtest",
        "uploaderAvatarUrl": "https://tt.example.com/avatar.jpg",
        "thumbnailUrl": "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
        "duration": 212,
        "viewCount": 12345,
        "likeCount": 678,
        "uploadDate": "Jan 1, 2021",
        "uploaded": 1609459200000,
        "streamType": "video",
        "isLive": false,
        "isPostLive": false,
        "isLiveContent": false,
        "hasLiveManifest": false,
        "hlsUrl": null,
        "dashMpdUrl": null,
        "videoStreams": [
            {
                "url": "https://tt.example.com/sabr/x",
                "mimeType": "video/mp4",
                "format": "mp4",
                "resolution": "1080p60",
                "bitrate": 5000000,
                "codec": "avc1.640028",
                "isVideoOnly": true,
                "itag": 313,
                "width": 1920,
                "height": 1080,
                "fps": 60,
                "contentLength": 100000
            }
        ],
        "audioStreams": [
            {
                "url": "https://tt.example.com/sabr/a",
                "mimeType": "audio/mp4",
                "format": "mp4",
                "bitrate": 128000,
                "codec": "mp4a.40.2",
                "quality": "medium",
                "itag": 140,
                "contentLength": 30000,
                "isOriginal": true
            }
        ],
        "videoOnlyStreams": [
            {
                "url": "https://tt.example.com/sabr/y",
                "mimeType": "video/webm",
                "format": "webm",
                "resolution": "720p30",
                "bitrate": 2000000,
                "codec": "vp9",
                "isVideoOnly": true,
                "itag": 247,
                "width": 1280,
                "height": 720,
                "fps": 30,
                "contentLength": 50000
            }
        ],
        "subtitles": [
            {
                "url": "https://tt.example.com/subs/en.vtt",
                "mimeType": "text/vtt",
                "languageTag": "en",
                "displayLanguageName": "English",
                "isAutoGenerated": false
            }
        ],
        "relatedStreams": []
    }
    """

    static let liveJSON = """
    {
        "id": "live1234567",
        "title": "Live Stream",
        "description": "",
        "uploaderName": "Live Channel",
        "uploaderUrl": "https://www.youtube.com/channel/UClive",
        "thumbnailUrl": "https://i.ytimg.com/vi/live1234567/hqdefault.jpg",
        "duration": -1,
        "viewCount": 42,
        "uploadDate": "",
        "uploaded": -1,
        "streamType": "live",
        "isLive": true,
        "isPostLive": false,
        "isLiveContent": true,
        "hasLiveManifest": true,
        "hlsUrl": "https://manifest.example.com/hls/master.m3u8",
        "videoStreams": [],
        "audioStreams": [],
        "videoOnlyStreams": [],
        "subtitles": [],
        "relatedStreams": []
    }
    """
}

@Suite("TypeType List Mapping")
struct TypeTypeListMappingTests {
    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try HTTPClient.makeAPIDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("Sentinel values are dropped like missing values")
    func sentinelsAreDropped() throws {
        let item = try decode(TypeTypeVideoItem.self, from: """
        {
            "id": "abc12345678",
            "title": "Sentinels",
            "url": "https://www.youtube.com/watch?v=abc12345678",
            "thumbnailUrl": "https://i.ytimg.com/vi/abc12345678/hqdefault.jpg",
            "uploaderName": "Channel",
            "uploaderUrl": "https://www.youtube.com/channel/UCx",
            "duration": -1,
            "viewCount": -1,
            "uploadDate": "",
            "uploaded": -1,
            "streamType": "video",
            "isLive": false,
            "isPostLive": false,
            "isLiveContent": false,
            "isShortFormContent": false,
            "uploaderVerified": false
        }
        """)

        let video = item.toVideo()
        #expect(video.viewCount == nil)
        #expect(video.publishedAt == nil)
        #expect(video.isShort == false)
    }

    @Test("A row with real numbers keeps them, milliseconds and all")
    func realValuesSurvive() throws {
        let item = try decode(TypeTypeVideoItem.self, from: """
        {
            "id": "real1234567",
            "title": "Real",
            "url": "https://www.youtube.com/watch?v=real1234567",
            "thumbnailUrl": "https://i.ytimg.com/vi/real1234567/hqdefault.jpg",
            "uploaderName": "Channel",
            "uploaderUrl": "https://www.youtube.com/channel/UCx",
            "duration": 300,
            "viewCount": 4200,
            "uploadDate": "Jan 1, 2021",
            "uploaded": 1609459200000,
            "streamType": "video",
            "isLive": false,
            "isPostLive": false,
            "isLiveContent": false,
            "isShortFormContent": true,
            "uploaderVerified": true
        }
        """)

        let video = item.toVideo()
        #expect(video.viewCount == 4200)
        #expect(video.publishedAt == Date(timeIntervalSince1970: 1_609_459_200))
        #expect(video.isShort == true)
        #expect(video.author.id == "https://www.youtube.com/channel/UCx")
    }

    @Test("Search pages map videos, channels and playlists")
    func searchPageMapsAllKinds() throws {
        let response = try decode(TypeTypeSearchResponse.self, from: """
        {
            "items": [
                {
                    "id": "vid12345678",
                    "title": "A Video",
                    "url": "https://www.youtube.com/watch?v=vid12345678",
                    "thumbnailUrl": "https://i.ytimg.com/vi/vid12345678/hqdefault.jpg",
                    "uploaderName": "Channel",
                    "uploaderUrl": "https://www.youtube.com/channel/UCx",
                    "duration": 60,
                    "viewCount": 10,
                    "uploadDate": "Jan 1, 2021",
                    "uploaded": 1609459200000,
                    "streamType": "video",
                    "isLive": false,
                    "isPostLive": false,
                    "isLiveContent": false,
                    "isShortFormContent": false,
                    "uploaderVerified": false
                }
            ],
            "nextpage": "CAoQAA",
            "isCorrectedSearch": false,
            "playlists": [
                {
                    "id": "PLtest123",
                    "title": "A Playlist",
                    "url": "https://www.youtube.com/playlist?list=PLtest123",
                    "thumbnailUrl": "https://i.ytimg.com/vi/abc/hqdefault.jpg",
                    "uploaderName": "Channel",
                    "streamCount": 5,
                    "playlistType": "playlist"
                }
            ],
            "channels": [
                {
                    "id": "UCx",
                    "name": "A Channel",
                    "url": "https://www.youtube.com/channel/UCx",
                    "thumbnailUrl": "https://tt.example.com/avatar.jpg",
                    "description": "About",
                    "subscriberCount": 100,
                    "streamCount": 20,
                    "isVerified": true
                }
            ]
        }
        """)

        #expect(response.items.map(\.id) == ["vid12345678"])
        #expect(response.nextpage == "CAoQAA")
        #expect(response.playlists?.map(\.id) == ["PLtest123"])
        #expect(response.channels?.map(\.id) == ["UCx"])

        let channel = try #require(response.channels?.first?.toChannel())
        #expect(channel.id.channelID == "https://www.youtube.com/channel/UCx")
        #expect(channel.isVerified)
    }

    @Test("Comments map to Yattee's model")
    func commentsMap() throws {
        let response = try decode(TypeTypeCommentsResponse.self, from: """
        {
            "comments": [
                {
                    "id": "c1",
                    "text": "Nice video",
                    "author": "Someone",
                    "authorUrl": "https://www.youtube.com/channel/UCy",
                    "authorAvatarUrl": "https://tt.example.com/a.jpg",
                    "likeCount": 3,
                    "textualLikeCount": "3",
                    "publishedTime": "1 day ago",
                    "publishedAt": 1609459200000,
                    "isHeartedByUploader": true,
                    "isPinned": false,
                    "uploaderVerified": false,
                    "replyCount": 2,
                    "repliesPage": "token"
                }
            ],
            "nextpage": null,
            "commentsDisabled": false
        }
        """)

        let comment = try #require(response.comments.first?.toComment())
        #expect(comment.content == "Nice video")
        #expect(comment.likeCount == 3)
        #expect(comment.hasCreatorHeart)
        #expect(comment.replyCount == 2)
        #expect(comment.repliesContinuation == "token")
        #expect(comment.publishedAt == Date(timeIntervalSince1970: 1_609_459_200))
    }
}
