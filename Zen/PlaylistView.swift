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

    var name: String {
        switch self {
        case .folder(let folder):
            return folder.name
        case .playlist(let playlist):
            return playlist.name
        }
    }

    var createdAt: Date {
        switch self {
        case .folder(let folder):
            return folder.createdAt
        case .playlist(let playlist):
            return playlist.createdAt
        }
    }
}

struct PlaylistsTab: View {
    @ObservedObject var playerManager: PlayerManager
    var allSongs: [Song]
    var onRefresh: () -> Void
    var onOpenSettings: (() -> Void)? = nil
    
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
    /// When creating a new playlist, the folder to put it in (nil = top level).
    @State private var targetParentFolder: Folder? = nil
    @State private var sortMode: FolderSortMode = .custom

    /// Cached so we don't recompute on every body run (e.g. when playerManager.currentSong changes).
    @State private var cachedCombinedItems: [PlaylistItem] = []

    // Multi-select state
    @State private var isSelectMode = false
    @State private var selectedItems: Set<PersistentIdentifier> = []

    private func updateCombinedItemsCache() {
        let folders = allFolders.filter { $0.modelContext != nil && $0.parent == nil }
        let playlists = allPlaylists.filter { $0.modelContext != nil && $0.parentFolder == nil }

        var items: [PlaylistItem] = []

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            let matchingFolders = folders.filter { $0.name.lowercased().contains(query) }
            items.append(contentsOf: matchingFolders.map { PlaylistItem.folder($0) })
            let matchingTopPlaylists = playlists.filter { $0.name.lowercased().contains(query) }
            items.append(contentsOf: matchingTopPlaylists.map { PlaylistItem.playlist($0) })
            let matchingPlaylistsInFolders = getAllMatchingPlaylistsInFolders(folders: folders, query: query)
            items.append(contentsOf: matchingPlaylistsInFolders.map { PlaylistItem.playlist($0) })
            let foldersWithMatchingPlaylists = folders.filter {
                !$0.name.lowercased().contains(query) && folderContainsMatchingPlaylist($0, query: query)
            }
            items.append(contentsOf: foldersWithMatchingPlaylists.map { PlaylistItem.folder($0) })
        } else {
            items.append(contentsOf: folders.map { PlaylistItem.folder($0) })
            items.append(contentsOf: playlists.map { PlaylistItem.playlist($0) })
        }

        cachedCombinedItems = sortItems(items)
    }

    private func sortItems(_ items: [PlaylistItem]) -> [PlaylistItem] {
        switch sortMode {
        case .aToZ:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .zToA:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .dateAdded:
            return items.sorted { $0.createdAt < $1.createdAt }
        case .custom:
            return items.sorted { $0.sortOrder < $1.sortOrder }
        }
    }
    
    // Recursively get all playlists from folders that match the query
    private func getAllMatchingPlaylistsInFolders(folders: [Folder], query: String) -> [Playlist] {
        var matchingPlaylists: [Playlist] = []
        
        for folder in folders {
            // Check playlists directly in this folder
            for playlist in folder.playlists {
                if playlist.name.lowercased().contains(query) {
                    matchingPlaylists.append(playlist)
                }
            }
            
            // Recursively check subfolders
            matchingPlaylists.append(contentsOf: getAllMatchingPlaylistsInFolders(folders: folder.subFolders, query: query))
        }
        
        return matchingPlaylists
    }
    
    // Recursively check if a folder or its subfolders contain a matching playlist
    private func folderContainsMatchingPlaylist(_ folder: Folder, query: String) -> Bool {
        // Check playlists directly in this folder
        for playlist in folder.playlists {
            if playlist.name.lowercased().contains(query) {
                return true
            }
        }
        
        // Recursively check subfolders
        for subFolder in folder.subFolders {
            if folderContainsMatchingPlaylist(subFolder, query: query) {
                return true
            }
        }
        
        return false
    }
    
    /// "New Playlist" destination: single button if folder has no sub-folders, dropdown if it has sub-folders.
    @ViewBuilder
    private func newPlaylistFolderSubmenu(folder: Folder) -> some View {
        if folder.subFolders.isEmpty {
            Button(folder.name) {
                targetParentFolder = folder
                isCreatingFolder = false
                newItemName = ""
                showingNameAlert = true
            }
        } else {
            Menu(folder.name) {
                Button("In \(folder.name)") {
                    targetParentFolder = folder
                    isCreatingFolder = false
                    newItemName = ""
                    showingNameAlert = true
                }
                ForEach(folder.subFolders.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.persistentModelID) { sub in
                    AnyView(newPlaylistFolderSubmenu(folder: sub))
                }
            }
        }
    }
    
    private func createNewItem() {
        if isCreatingFolder {
            modelContext.insert(Folder(name: newItemName))
        } else {
            let playlist = Playlist(name: newItemName)
            playlist.parentFolder = targetParentFolder
            if let parent = targetParentFolder {
                let nextOrder = (parent.playlists.map(\.sortOrder).max() ?? -1) + 1
                playlist.sortOrder = nextOrder
                parent.playlists.append(playlist)
            } else {
                let rootPlaylists = allPlaylists.filter { $0.modelContext != nil && $0.parentFolder == nil }
                let nextOrder = (rootPlaylists.map(\.sortOrder).max() ?? -1) + 1
                playlist.sortOrder = nextOrder
            }
            modelContext.insert(playlist)
        }
        newItemName = ""
        targetParentFolder = nil
        try? modelContext.save()
    }
    
    /// "Move to Folder": single button if folder has no sub-folders, dropdown if it has sub-folders.
    @ViewBuilder
    private func movePlaylistFolderSubmenu(folder: Folder, playlist: Playlist) -> some View {
        if folder.subFolders.isEmpty {
            Button(folder.name) {
                playlist.parentFolder = folder
                try? modelContext.save()
                updateCombinedItemsCache()
            }
        } else {
            Menu(folder.name) {
                Button("In \(folder.name)") {
                    playlist.parentFolder = folder
                    try? modelContext.save()
                    updateCombinedItemsCache()
                }
                ForEach(folder.subFolders.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.persistentModelID) { sub in
                    AnyView(movePlaylistFolderSubmenu(folder: sub, playlist: playlist))
                }
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(cachedCombinedItems) { item in
                        itemRow(for: item)
                    }
                    .onMove { from, to in
                        moveItems(from: from, to: to)
                    }
                    .moveDisabled(sortMode != .custom)
                }
                
                // Add bottom padding so mini player doesn't cover last playlist
                if playerManager.currentSong != nil {
                    Color.clear
                        .frame(height: 120)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Playlists")
            .searchable(text: $searchText)
            .onAppear {
                sortMode = getFolderSortMode(for: nil)
                updateCombinedItemsCache()
            }
            .onChange(of: searchText) { _, _ in updateCombinedItemsCache() }
            .onChange(of: allFolders.count) { _, _ in updateCombinedItemsCache() }
            .onChange(of: allPlaylists.count) { _, _ in updateCombinedItemsCache() }
            .onChange(of: sortMode) { _, newMode in
                setFolderSortMode(for: nil, mode: newMode)
                updateCombinedItemsCache()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectMode {
                        Button("Done") {
                            isSelectMode = false
                            selectedItems.removeAll()
                        }
                        .foregroundColor(.yellow)
                    } else {
                        Button { onOpenSettings?() } label: {
                            Image(systemName: "gearshape")
                                .foregroundColor(.yellow)
                        }
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelectMode {
                        // Delete selected button
                        Button {
                            deleteSelectedItems()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(selectedItems.isEmpty ? .gray : .red)
                        }
                        .disabled(selectedItems.isEmpty)
                    } else {
                        // Sort menu
                        Menu {
                            ForEach(FolderSortMode.allCases, id: \.self) { mode in
                                Button {
                                    sortMode = mode
                                } label: {
                                    HStack {
                                        Text(mode.rawValue)
                                        if sortMode == mode { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .foregroundColor(.yellow)
                        }

                        // Refresh Button
                        Button {
                            try? modelContext.delete(model: Song.self)
                            onRefresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.yellow)
                        }

                        // Select button
                        Button {
                            isSelectMode = true
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.yellow)
                        }

                        if sortMode == .custom {
                            EditButton().foregroundColor(.yellow)
                        }

                        Menu {
                            Button("New Folder") {
                                isCreatingFolder = true
                                targetParentFolder = nil
                                showingNameAlert = true
                            }
                            Menu("New Playlist") {
                                Button("At top level") {
                                    isCreatingFolder = false
                                    targetParentFolder = nil
                                    newItemName = ""
                                    showingNameAlert = true
                                }
                                let topFolders = allFolders.filter { $0.modelContext != nil && $0.parent == nil }
                                ForEach(topFolders.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.persistentModelID) { folder in
                                    newPlaylistFolderSubmenu(folder: folder)
                                }
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill").foregroundColor(.yellow)
                        }
                    }
                }
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
                    createNewItem()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func itemRow(for item: PlaylistItem) -> some View {
        let isSelected = selectedItems.contains(item.id)

        switch item {
        case .folder(let folder):
            if isSelectMode {
                Button {
                    toggleSelection(item.id)
                } label: {
                    HStack(spacing: 12) {
                        // Selection indicator
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .yellow : .gray)
                            .font(.title2)

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
                            .foregroundColor(.primary)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            } else {
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
            }
        case .playlist(let playlist):
            if isSelectMode {
                Button {
                    toggleSelection(item.id)
                } label: {
                    HStack(spacing: 12) {
                        // Selection indicator
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .yellow : .gray)
                            .font(.title2)

                        // Playlist artwork mosaic
                        PlaylistArtworkView(playlist: playlist)
                            .frame(width: 60, height: 60)
                            .cornerRadius(8)

                        Text(playlist.name)
                            .font(.body)
                            .foregroundColor(.primary)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            } else {
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
                        Button("Root (No Folder)") {
                            playlist.parentFolder = nil
                            try? modelContext.save()
                            updateCombinedItemsCache()
                        }
                        let topFolders = allFolders.filter { $0.modelContext != nil && $0.parent == nil }
                        ForEach(topFolders.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.persistentModelID) { folder in
                            movePlaylistFolderSubmenu(folder: folder, playlist: playlist)
                        }
                    }
                    Button("Delete", role: .destructive) { modelContext.delete(playlist) }
                }
            }
        }
    }

    private func toggleSelection(_ id: PersistentIdentifier) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
        } else {
            selectedItems.insert(id)
        }
    }

    private func deleteSelectedItems() {
        for item in cachedCombinedItems {
            if selectedItems.contains(item.id) {
                switch item {
                case .folder(let folder):
                    modelContext.delete(folder)
                case .playlist(let playlist):
                    modelContext.delete(playlist)
                }
            }
        }
        try? modelContext.save()
        selectedItems.removeAll()
        isSelectMode = false
        updateCombinedItemsCache()
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        var items = cachedCombinedItems
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
        updateCombinedItemsCache()
    }
}

// MARK: - Playlist Artwork View
struct PlaylistArtworkView: View {
    let playlist: Playlist
    
    var songs: [Song] {
        orderedPlaylistSongs(playlist: playlist, songs: playlist.songs ?? [])
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
