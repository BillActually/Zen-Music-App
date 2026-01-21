import Foundation
import SwiftData

@Model
class Folder {
    var name: String
    var sortOrder: Int // Add this line
    
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
