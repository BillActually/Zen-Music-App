import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

enum PlaylistItem: Identifiable {
    case folder(Folder)
    case playlist(Playlist)
    
    var id: PersistentIdentifier {
        switch self {
        case .folder(let folder):
            return folder.persistentModelID
        case .playlist(let playlist):
            return playlist.persistentModelID
        }
    }
    
    var sortOrder: Int {
        switch self {
        case .folder(let folder):
            return folder.sortOrder
        case .playlist(let playlist):
            return playlist.sortOrder
        }
    }
}

struct PlaylistsTab: View {
    @ObservedObject var playerManager: PlayerManager
    var allSongs: [Song]
    var onRefresh: () -> Void
    
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]
    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]

    @State private var showingAddOptions = false
    @State private var newItemName = ""
    @State private var isCreatingFolder = false
    @State private var showingNameAlert = false
    @State private var folderToRename: Folder?
    @State private var playlistToRename: Playlist?
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var searchText = ""

    var combinedItems: [PlaylistItem] {
        let folders = allFolders.filter { $0.modelContext != nil && $0.parent == nil }
        let playlists = allPlaylists.filter { $0.modelContext != nil && $0.parentFolder == nil }
        
        var items: [PlaylistItem] = []
        items.append(contentsOf: folders.map { PlaylistItem.folder($0) })
        items.append(contentsOf: playlists.map { PlaylistItem.playlist($0) })
        
        return items.sorted { $0.sortOrder < $1.sortOrder }
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(combinedItems) { item in
                        itemRow(for: item)
                    }
                    .onMove { from, to in
                        moveItems(from: from, to: to)
                    }
                }
            }
            .navigationTitle("Playlists")
            .searchable(text: $searchText)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // 2. Add the Refresh Button here
                    Button {
                        // 1. Wipe the current duplicates from the database
                        // This removes all 'Song' entries so the sync starts fresh
                        try? modelContext.delete(model: Song.self)
                        
                        // 2. Simply trigger the fresh sync logic
                        // Your syncLocalFiles logic will now see 0 existing songs and re-import them correctly
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.green)
                    }

                    EditButton().foregroundColor(.green)
                    
                    Button { showingAddOptions = true } label: {
                        Image(systemName: "plus.circle.fill").foregroundColor(.green)
                    }
                }
            }
            .confirmationDialog("Add New", isPresented: $showingAddOptions) {
                Button("New Folder") { isCreatingFolder = true; showingNameAlert = true }
                Button("New Playlist") { isCreatingFolder = false; showingNameAlert = true }
            }
            .alert("Rename", isPresented: $isRenaming) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let f = folderToRename { f.name = renameText }
                    if let p = playlistToRename { p.name = renameText }
                    try? modelContext.save()
                    folderToRename = nil
                    playlistToRename = nil
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(isCreatingFolder ? "New Folder" : "New Playlist", isPresented: $showingNameAlert) {
                TextField("Name", text: $newItemName)
                Button("Create") {
                    if isCreatingFolder {
                        modelContext.insert(Folder(name: newItemName))
                    } else {
                        modelContext.insert(Playlist(name: newItemName))
                    }
                    newItemName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func itemRow(for item: PlaylistItem) -> some View {
        switch item {
        case .folder(let folder):
            NavigationLink(destination: FolderDetailView(folder: folder, playerManager: playerManager, allSongs: allSongs)) {
                HStack(spacing: 12) {
                    // Folder icon
                    ZStack {
                        Color.yellow.opacity(0.2)
                        Image(systemName: "folder.fill")
                            .foregroundColor(.yellow)
                            .font(.title2)
                    }
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    
                    Text(folder.name)
                        .font(.body)
                    
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .contextMenu {
                Button("Rename") {
                    renameText = folder.name
                    folderToRename = folder
                    isRenaming = true
                }
                Button("Delete", role: .destructive) { modelContext.delete(folder) }
            }
        case .playlist(let playlist):
            NavigationLink(destination: PlaylistDetailView(playlist: playlist, playerManager: playerManager, allSongs: allSongs)) {
                HStack(spacing: 12) {
                    // Playlist artwork mosaic
                    PlaylistArtworkView(playlist: playlist)
                        .frame(width: 60, height: 60)
                        .cornerRadius(8)
                    
                    Text(playlist.name)
                        .font(.body)
                    
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .contextMenu {
                Button("Rename") {
                    renameText = playlist.name
                    playlistToRename = playlist
                    isRenaming = true
                }
                Menu("Move to Folder") {
                    ForEach(allFolders.filter { $0.modelContext != nil && $0.parent == nil }) { folder in
                        Button(folder.name) {
                            playlist.parentFolder = folder
                            try? modelContext.save()
                        }
                    }
                }
                Button("Delete", role: .destructive) { modelContext.delete(playlist) }
            }
        }
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        var items = combinedItems
        items.move(fromOffsets: source, toOffset: destination)
        
        for (index, item) in items.enumerated() {
            switch item {
            case .folder(let folder):
                folder.sortOrder = index
            case .playlist(let playlist):
                playlist.sortOrder = index
            }
        }
        try? modelContext.save()
    }
}

// MARK: - Playlist Artwork View
struct PlaylistArtworkView: View {
    let playlist: Playlist
    
    var songs: [Song] {
        playlist.songs ?? []
    }
    
    // Count unique albums
    var uniqueAlbums: Set<String> {
        Set(songs.map { $0.album })
    }
    
    var uniqueAlbumCount: Int {
        uniqueAlbums.count
    }
    
    // Get first song from each unique album for the grid
    var songsForGrid: [Song] {
        var seenAlbums = Set<String>()
        var result: [Song] = []
        
        for song in songs {
            if !seenAlbums.contains(song.album) {
                seenAlbums.insert(song.album)
                result.append(song)
                if result.count >= 4 {
                    break
                }
            }
        }
        
        return result
    }
    
    var body: some View {
        let songCount = songs.count
        
        if songCount == 0 {
            // Empty playlist - show placeholder
            ZStack {
                Color.gray.opacity(0.2)
                Image(systemName: "music.note.list")
                    .foregroundColor(.gray)
            }
        } else if uniqueAlbumCount < 4 {
            // Less than 4 unique albums: Show full-sized artwork of first song
            // Always use the first song, regardless of how many songs are added
            if let firstSong = songs.first {
                songArtworkView(song: firstSong)
            }
        } else {
            // 4+ unique albums: Show 2x2 grid of first song from each of first 4 unique albums
            let gridSongs = songsForGrid
            if gridSongs.count == 4 {
                GridView(songs: gridSongs)
            } else {
                // Fallback (shouldn't happen, but just in case)
                if let firstSong = songs.first {
                    songArtworkView(song: firstSong)
                }
            }
        }
    }
    
    @ViewBuilder
    private func songArtworkView(song: Song) -> some View {
        // MEMORY OPTIMIZATION: Use SongArtworkView which handles downscaling
        SongArtworkView(song: song, size: 60)
    }
}

// MARK: - Grid View for 4-song mosaic
struct GridView: View {
    let songs: [Song]
    
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                artworkTile(song: songs[0])
                artworkTile(song: songs[1])
            }
            HStack(spacing: 2) {
                artworkTile(song: songs[2])
                artworkTile(song: songs[3])
            }
        }
    }
    
    @ViewBuilder
    private func artworkTile(song: Song) -> some View {
        // MEMORY OPTIMIZATION: Use SongArtworkView which handles downscaling
        SongArtworkView(song: song, size: 29)
    }
}
