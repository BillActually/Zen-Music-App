import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct FolderDetailView: View {
    @Bindable var folder: Folder
    var playerManager: PlayerManager
    var allSongs: [Song]

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]

    @State private var showingAddOptions = false
    @State private var showingNameAlert = false
    @State private var newItemName = ""
    @State private var isCreatingFolder = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var folderToRename: Folder?
    @State private var playlistToRename: Playlist?
    @State private var listRefreshId = 0
    @State private var sortMode: FolderSortMode = .custom

    private var combinedItems: [PlaylistItem] {
        var items: [PlaylistItem] = []
        items.append(contentsOf: folder.subFolders.map { PlaylistItem.folder($0) })
        items.append(contentsOf: folder.playlists.map { PlaylistItem.playlist($0) })
        return sortItems(items)
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

    var body: some View {
        List {
            Section {
                ForEach(combinedItems) { item in
                    itemRow(for: item)
                }
                .onMove { from, to in
                    moveItems(from: from, to: to)
                }
                .moveDisabled(sortMode != .custom)
            }

            // Add bottom padding so mini player doesn't cover last item
            if playerManager.currentSong != nil {
                Color.clear
                    .frame(height: 120)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .id(listRefreshId)
        .navigationTitle(folder.name)
        .onAppear {
            sortMode = getFolderSortMode(for: folder)
        }
        .onChange(of: sortMode) { _, newMode in
            setFolderSortMode(for: folder, mode: newMode)
            listRefreshId += 1
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
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

                if sortMode == .custom {
                    EditButton().foregroundColor(.yellow)
                }

                Button { showingAddOptions = true } label: {
                    Image(systemName: "plus.circle.fill").foregroundColor(.yellow)
                }
            }
        }
        .confirmationDialog("Add", isPresented: $showingAddOptions) {
            Button("New Sub-folder") { isCreatingFolder = true; showingNameAlert = true }
            Button("New Playlist") { isCreatingFolder = false; showingNameAlert = true }
        }
        .alert(isCreatingFolder ? "New Sub-folder" : "New Playlist", isPresented: $showingNameAlert) {
            TextField("Name", text: $newItemName)
            Button("Create") { createItem() }
            Button("Cancel", role: .cancel) {}
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
    }

    @ViewBuilder
    private func itemRow(for item: PlaylistItem) -> some View {
        switch item {
        case .folder(let subFolder):
            NavigationLink(destination: FolderDetailView(folder: subFolder, playerManager: playerManager, allSongs: allSongs)) {
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

                    Text(subFolder.name)
                        .font(.body)

                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .contextMenu {
                Button("Rename") {
                    renameText = subFolder.name
                    folderToRename = subFolder
                    isRenaming = true
                }
                Menu("Move to Folder") {
                    Button("Root (No Folder)") {
                        subFolder.parent = nil
                        try? modelContext.save()
                        listRefreshId += 1
                    }
                    ForEach(allFolders.filter { targetFolder in
                        targetFolder.persistentModelID != folder.persistentModelID &&
                        targetFolder.persistentModelID != subFolder.persistentModelID &&
                        !isDescendant(subFolder, of: targetFolder)
                    }) { targetFolder in
                        Button(targetFolder.name) {
                            subFolder.parent = targetFolder
                            try? modelContext.save()
                            listRefreshId += 1
                        }
                    }
                }
                Button("Delete", role: .destructive) {
                    modelContext.delete(subFolder)
                }
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
                    Button("Root (No Folder)") {
                        playlist.parentFolder = nil
                        try? modelContext.save()
                        listRefreshId += 1
                    }
                    ForEach(allFolders.filter { targetFolder in
                        targetFolder.persistentModelID != folder.persistentModelID
                    }) { targetFolder in
                        Button(targetFolder.name) {
                            playlist.parentFolder = targetFolder
                            try? modelContext.save()
                            listRefreshId += 1
                        }
                    }
                }
                Button("Delete", role: .destructive) {
                    modelContext.delete(playlist)
                }
            }
        }
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        var items = combinedItems
        items.move(fromOffsets: source, toOffset: destination)

        for (index, item) in items.enumerated() {
            switch item {
            case .folder(let subFolder):
                subFolder.sortOrder = index
            case .playlist(let playlist):
                playlist.sortOrder = index
            }
        }
        try? modelContext.save()
    }

    private func createItem() {
        let currentCount = combinedItems.count
        if isCreatingFolder {
            let newFolder = Folder(name: newItemName, parent: folder)
            newFolder.sortOrder = currentCount
            folder.subFolders.append(newFolder)
        } else {
            let newPlaylist = Playlist(name: newItemName)
            newPlaylist.parentFolder = folder
            newPlaylist.sortOrder = currentCount
            folder.playlists.append(newPlaylist)
        }
        newItemName = ""
    }

    // Helper function to check if a folder is a descendant of another folder (prevents circular references)
    private func isDescendant(_ folder: Folder, of ancestor: Folder) -> Bool {
        var current: Folder? = folder.parent
        while let parent = current {
            if parent.persistentModelID == ancestor.persistentModelID {
                return true
            }
            current = parent.parent
        }
        return false
    }
}
