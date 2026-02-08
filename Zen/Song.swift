import Foundation
import SwiftData

@Model
class Folder {
    var name: String
    var sortOrder: Int
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
    var subFolders: [Folder] = []

    var parent: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Playlist.parentFolder)
    var playlists: [Playlist] = []

    init(name: String, sortOrder: Int = 0, parent: Folder? = nil) {
        self.name = name
        self.sortOrder = sortOrder
        self.parent = parent
    }
}

@Model
final class Playlist {
    var name: String
    var sortOrder: Int
    var createdAt: Date = Date()

    // 1. Explicitly define the relationship and the inverse
    @Relationship(inverse: \Song.playlists)
    var songs: [Song]? = []

    var parentFolder: Folder?

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
        self.songs = []
        self.parentFolder = nil
    }
}

@Model
final class Song: Identifiable {
    @Attribute(.unique) var url: URL
    var id: URL { url }

    var title: String = "Unknown Title"
    var artist: String = "Unknown Artist"
    var album: String = "Unknown Album"
    /// When true, song is hidden from the Library tab only; still appears in Artists, Albums, Playlists, etc.
    var hiddenFromLibrary: Bool = false
    
    @Relationship(deleteRule: .cascade)
    var artworkContainer: SongArtwork?
    var playlists: [Playlist]? = []

    init(title: String, artist: String, album: String, url: URL) {
        self.title = title
        self.artist = artist
        self.album = album
        self.url = url
        self.playlists = []
    }
}

@Model
class SongArtwork {
    // This keyword is the most important part for 6,000+ songs
    @Attribute(.externalStorage)
    var data: Data?
    
    init(data: Data?) {
        self.data = data
    }
}

/// History log entry for settings: added/deleted from library, added/removed from playlists.
@Model
final class HistoryEntry {
    var date: Date
    var action: String // "added_to_library", "deleted_from_library", "added_to_playlist", "removed_from_playlist"
    var songTitle: String
    var songArtist: String
    var playlistName: String?
    
    init(date: Date = .now, action: String, songTitle: String, songArtist: String, playlistName: String? = nil) {
        self.date = date
        self.action = action
        self.songTitle = songTitle
        self.songArtist = songArtist
        self.playlistName = playlistName
    }
}

/// One play event for "Wrapped" style stats. Reset scope: only current calendar year is retained.
@Model
final class PlayRecord {
    var date: Date
    var songURL: URL
    var songTitle: String
    var songArtist: String
    
    init(date: Date = .now, songURL: URL, songTitle: String, songArtist: String) {
        self.date = date
        self.songURL = songURL
        self.songTitle = songTitle
        self.songArtist = songArtist
    }
}
