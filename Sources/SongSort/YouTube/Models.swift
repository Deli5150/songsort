import Foundation

struct Song: Identifiable, Hashable, Sendable {
    var videoId: String
    /// Identifies this entry inside its playlist; removing a song from a playlist needs it.
    var setVideoId: String?
    var title: String
    var artists: String
    var album: String?
    var thumbnailURL: String?
    var duration: String?

    var id: String { videoId }
    var watchURL: URL { URL(string: "https://music.youtube.com/watch?v=\(videoId)")! }
}

struct Playlist: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var thumbnailURL: String?
    /// e.g. "Delvison • 45 tracks" — shown under the title in pickers.
    var subtitle: String?
}

/// The playlist being sorted. Liked Songs is YouTube Music's "LM" playlist.
struct SongSource: Hashable, Sendable {
    var id: String
    var title: String

    static let likedID = "LM"
    static let liked = SongSource(id: likedID, title: "Liked Songs")
    var isLiked: Bool { id == Self.likedID }
}

struct PlaylistMembership: Identifiable, Hashable, Sendable {
    var playlist: Playlist
    var containsSong: Bool
    var id: String { playlist.id }
}
