import Foundation
import SwiftData

// MARK: - Playlist song order (so new songs appear at the bottom)
private let orderPrefix = "zen.playlistOrder."

private func persistentIdString(_ id: PersistentIdentifier) -> String {
    String(describing: id)
}

func playlistOrderKey(for playlist: Playlist) -> String {
    orderPrefix + persistentIdString(playlist.persistentModelID)
}

func getPlaylistOrder(for playlist: Playlist) -> [String] {
    UserDefaults.standard.stringArray(forKey: playlistOrderKey(for: playlist)) ?? []
}

func setPlaylistOrder(for playlist: Playlist, songIds: [String]) {
    UserDefaults.standard.set(songIds, forKey: playlistOrderKey(for: playlist))
}

func appendSongToPlaylistOrder(playlist: Playlist, song: Song) {
    let key = playlistOrderKey(for: playlist)
    var order = UserDefaults.standard.stringArray(forKey: key) ?? []
    let id = persistentIdString(song.persistentModelID)
    if !order.contains(id) {
        order.append(id)
        UserDefaults.standard.set(order, forKey: key)
    }
    setPlaylistAddedAt(playlist: playlist, song: song, date: Date())
}

func removeSongFromPlaylistOrder(playlist: Playlist, song: Song) {
    let key = playlistOrderKey(for: playlist)
    var order = UserDefaults.standard.stringArray(forKey: key) ?? []
    let id = persistentIdString(song.persistentModelID)
    order.removeAll { $0 == id }
    UserDefaults.standard.set(order, forKey: key)
    removePlaylistAddedAt(playlist: playlist, song: song)
}

/// Initialize order from current `songs` (e.g. after M3U import or first use).
func setPlaylistOrderFromSongs(playlist: Playlist, songs: [Song]) {
    setPlaylistOrder(for: playlist, songIds: songs.map { persistentIdString($0.persistentModelID) })
}

/// Returns `songs` in the stored order; new songs (not in order) appear at the end.
func orderedPlaylistSongs(playlist: Playlist, songs: [Song]) -> [Song] {
    let order = getPlaylistOrder(for: playlist)
    if order.isEmpty { return songs }
    let byId = Dictionary(uniqueKeysWithValues: songs.map { (persistentIdString($0.persistentModelID), $0) })
    var result: [Song] = []
    for id in order {
        if let song = byId[id] { result.append(song) }
    }
    for song in songs where !order.contains(persistentIdString(song.persistentModelID)) {
        result.append(song)
    }
    return result
}

// MARK: - Date added to playlist (for "Date added" sort; precision to the second)
private let addedAtPrefix = "zen.playlistAddedAt."

private func playlistAddedAtKey(playlist: Playlist, song: Song) -> String {
    addedAtPrefix + persistentIdString(playlist.persistentModelID) + "." + persistentIdString(song.persistentModelID)
}

func setPlaylistAddedAt(playlist: Playlist, song: Song, date: Date) {
    UserDefaults.standard.set(date.timeIntervalSince1970, forKey: playlistAddedAtKey(playlist: playlist, song: song))
}

func removePlaylistAddedAt(playlist: Playlist, song: Song) {
    UserDefaults.standard.removeObject(forKey: playlistAddedAtKey(playlist: playlist, song: song))
}

func getPlaylistAddedAt(playlist: Playlist, song: Song) -> Date? {
    let interval = UserDefaults.standard.double(forKey: playlistAddedAtKey(playlist: playlist, song: song))
    guard interval > 0 else { return nil }
    return Date(timeIntervalSince1970: interval)
}

/// Returns `songs` sorted by date added to this playlist (oldest first, newest at bottom). Missing timestamp = at top.
func orderedPlaylistSongsByDateAdded(playlist: Playlist, songs: [Song]) -> [Song] {
    songs.sorted { s1, s2 in
        let t1 = getPlaylistAddedAt(playlist: playlist, song: s1) ?? .distantPast
        let t2 = getPlaylistAddedAt(playlist: playlist, song: s2) ?? .distantPast
        return t1 < t2
    }
}

// MARK: - Playlist sort mode (A–Z, Z–A, Artist, Album, Date added, Custom)
enum PlaylistSortMode: String, CaseIterable {
    case aToZ = "A–Z"
    case zToA = "Z–A"
    case artist = "Artist"
    case album = "Album"
    case dateAdded = "Date added"
    case custom = "Custom"
}

private let sortModePrefix = "zen.playlistSortMode."

func playlistSortModeKey(for playlist: Playlist) -> String {
    sortModePrefix + persistentIdString(playlist.persistentModelID)
}

func getPlaylistSortMode(for playlist: Playlist) -> PlaylistSortMode {
    let raw = UserDefaults.standard.string(forKey: playlistSortModeKey(for: playlist)) ?? PlaylistSortMode.custom.rawValue
    return PlaylistSortMode(rawValue: raw) ?? .custom
}

func setPlaylistSortMode(for playlist: Playlist, mode: PlaylistSortMode) {
    UserDefaults.standard.set(mode.rawValue, forKey: playlistSortModeKey(for: playlist))
}

// MARK: - Folder/Playlist list sort mode (A–Z, Z–A, Date added, Custom)
enum FolderSortMode: String, CaseIterable {
    case aToZ = "A–Z"
    case zToA = "Z–A"
    case dateAdded = "Date added"
    case custom = "Custom"
}

private let folderSortModeKey = "zen.folderSortMode.root"
private let folderSortModePrefix = "zen.folderSortMode."

func getFolderSortMode(for folder: Folder?) -> FolderSortMode {
    let key = folder == nil ? folderSortModeKey : folderSortModePrefix + persistentIdString(folder!.persistentModelID)
    let raw = UserDefaults.standard.string(forKey: key) ?? FolderSortMode.custom.rawValue
    return FolderSortMode(rawValue: raw) ?? .custom
}

func setFolderSortMode(for folder: Folder?, mode: FolderSortMode) {
    let key = folder == nil ? folderSortModeKey : folderSortModePrefix + persistentIdString(folder!.persistentModelID)
    UserDefaults.standard.set(mode.rawValue, forKey: key)
}

// MARK: - History log (Settings)
private let historyLogMaxCount = 100

func recordHistory(context: ModelContext, action: String, songTitle: String, songArtist: String, playlistName: String? = nil) {
    let entry = HistoryEntry(action: action, songTitle: songTitle, songArtist: songArtist, playlistName: playlistName)
    context.insert(entry)
    try? context.save()
    // Keep only the most recent entries
    let descriptor = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.date, order: .forward)])
    if let all = try? context.fetch(descriptor), all.count > historyLogMaxCount {
        let toRemove = all.prefix(all.count - historyLogMaxCount)
        for e in toRemove { context.delete(e) }
        try? context.save()
    }
}

// MARK: - Listening stats (Wrapped-style)

/// Records one play for listening stats. Call when a song starts playing.
func recordPlay(context: ModelContext, song: Song, date: Date = Date()) {
    let record = PlayRecord(date: date, songURL: song.url, songTitle: song.title, songArtist: song.artist)
    context.insert(record)
    try? context.save()
}

/// Deletes play records from before the current calendar year (stats reset per year).
func deletePlayRecordsBeforeCurrentYear(context: ModelContext) {
    let calendar = Calendar.current
    guard let startOfYear = calendar.date(from: calendar.dateComponents([.year], from: Date())) else { return }
    var descriptor = FetchDescriptor<PlayRecord>(sortBy: [SortDescriptor(\.date, order: .forward)])
    descriptor.fetchLimit = 10000
    guard let all = try? context.fetch(descriptor) else { return }
    let toDelete = all.filter { $0.date < startOfYear }
    for r in toDelete { context.delete(r) }
    if !toDelete.isEmpty { try? context.save() }
}

extension String {
    func fuzzyNormalized() -> String {
        // 1. Fold accents first (palé -> pale)
        let folded = self.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        
        // 2. Handle specific symbols
        let replacedSymbols = folded.replacingOccurrences(of: "$", with: "s")
        
        // 3. Keep only alphanumeric characters and spaces
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = replacedSymbols.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
            .lowercased()
        
        // 4. Clean up extra spaces
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
