import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var serverManager: TelegraphServerManager
    @ObservedObject var playerManager: PlayerManager
    @Query(sort: \Song.title) private var allSongs: [Song]
    
    /// Cached so we don't filter all songs on every body run (e.g. when player state changes).
    @State private var cachedHiddenCount: Int = 0
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        MetadataReportView()
                    } label: {
                        Label("Songs with missing metadata", systemImage: "doc.text.magnifyingglass")
                    }
                    NavigationLink {
                        HistoryLogView()
                    } label: {
                        Label("History log", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink {
                        DuplicateLogView()
                    } label: {
                        Label("Duplicate log", systemImage: "doc.on.doc")
                    }
                    NavigationLink {
                        HiddenSongsView(onUnhide: nil)
                    } label: {
                        Label("Hidden from library (\(cachedHiddenCount))", systemImage: "eye.slash")
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Reports songs where title, artist, or album could not be loaded (e.g. filename used as title). History log tracks songs added/deleted from library and added/removed from playlists. Duplicate log lists when two or more songs have the same title and artist. Hidden from library lists songs you've hidden from the Library tab only.")
                }
                Section {
                    NavigationLink {
                        ListeningStatsView()
                    } label: {
                        Label("Listening stats", systemImage: "chart.bar.fill")
                    }
                } header: {
                    Text("Stats")
                } footer: {
                    Text("Top 10 songs and artists for the past month and for the current year. Resets each calendar year.")
                }
                Section {
                    NavigationLink {
                        TelegraphTestView(serverManager: serverManager)
                    } label: {
                        Label("Start/stop server", systemImage: serverManager.isRunning ? "network" : "network.slash")
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Start or stop the file sharing server to transfer music to this device.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { cachedHiddenCount = allSongs.filter { $0.hiddenFromLibrary }.count }
            .onChange(of: allSongs.count) { _, _ in cachedHiddenCount = allSongs.filter { $0.hiddenFromLibrary }.count }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(.yellow)
                }
            }
        }
    }
}

struct MetadataReportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Song.title) private var allSongs: [Song]
    
    /// Songs that have metadata issues: unknown title/artist/album or title equals filename.
    private var songsWithMissingMetadata: [(song: Song, issues: [String])] {
        allSongs.compactMap { song in
            var issues: [String] = []
            if song.title == "Unknown Title" {
                issues.append("Unknown Title")
            }
            if song.artist == "Unknown Artist" {
                issues.append("Unknown Artist")
            }
            if song.album == "Unknown Album" {
                issues.append("Unknown Album")
            }
            let filenameStem = song.url.deletingPathExtension().lastPathComponent
            if song.title == filenameStem {
                issues.append("Title from filename")
            }
            if issues.isEmpty { return nil }
            return (song, issues)
        }
    }
    
    var body: some View {
        List {
            Section {
                if songsWithMissingMetadata.isEmpty {
                    Text("No songs with missing metadata.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(songsWithMissingMetadata, id: \.song.id) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.song.title)
                                .font(.headline)
                            Text(item.song.url.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(item.issues.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("\(songsWithMissingMetadata.count) song(s) with metadata issues")
            }
        }
        .navigationTitle("Missing metadata")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HistoryLogView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HistoryEntry.date, order: .reverse) private var entries: [HistoryEntry]
    
    private func label(for action: String) -> String {
        switch action {
        case "added_to_library": return "Added to library"
        case "deleted_from_library": return "Deleted from library"
        case "added_to_playlist": return "Added to playlist"
        case "removed_from_playlist": return "Removed from playlist"
        default: return action
        }
    }
    
    private func icon(for action: String) -> String {
        switch action {
        case "added_to_library": return "plus.circle.fill"
        case "deleted_from_library": return "trash.fill"
        case "added_to_playlist": return "text.badge.plus"
        case "removed_from_playlist": return "minus.circle.fill"
        default: return "circle"
        }
    }
    
    private func color(for action: String) -> Color {
        switch action {
        case "added_to_library": return .green
        case "deleted_from_library": return .red
        case "added_to_playlist": return .blue
        case "removed_from_playlist": return .orange
        default: return .primary
        }
    }
    
    var body: some View {
        List {
            if entries.isEmpty {
                Text("No history yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(entries, id: \.persistentModelID) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(for: entry.action))
                            .foregroundColor(color(for: entry.action))
                            .font(.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(for: entry.action))
                                .font(.subheadline.bold())
                            Text("\(entry.songTitle) — \(entry.songArtist)")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            if let playlist = entry.playlistName {
                                Text(playlist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.date, style: .date)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("History log")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Hashable key for grouping songs by title+artist (used as Dictionary key).
private struct DuplicateKey: Hashable {
    let title: String
    let artist: String
}

/// One duplicate group for DuplicateLogView: same title+artist, multiple song IDs (not Song refs to avoid crashes when a song is deleted elsewhere).
struct DuplicateGroup: Identifiable {
    var id: String { "\(title)|\(artist)" }
    let title: String
    let artist: String
    /// Store IDs only; resolve from current allSongs when rendering so deleted songs are never accessed.
    let songIDs: [URL]
}

struct DuplicateLogView: View {
    @Query(sort: \Song.title) private var allSongs: [Song]
    
    /// Groups of songs that share the same title and artist (case-insensitive). Only groups with 2+ songs.
    private var duplicateGroups: [DuplicateGroup] {
        let grouped = Dictionary(grouping: allSongs) { song in
            DuplicateKey(
                title: song.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                artist: song.artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return grouped
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(title: $0.key.title, artist: $0.key.artist, songIDs: $0.value.map(\.id)) }
            .sorted { ($0.title, $0.artist) < ($1.title, $1.artist) }
    }
    
    var body: some View {
        List {
            if duplicateGroups.isEmpty {
                emptyContent
            } else {
                ForEach(duplicateGroups) { group in
                    duplicateSection(group: group)
                }
            }
        }
        .navigationTitle("Duplicate log")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var emptyContent: some View {
        Text("No duplicates. No two songs share the same title and artist.")
            .foregroundColor(.secondary)
    }
    
    /// Resolve songs from current allSongs so we never touch a deleted Song object.
    private func songsForGroup(_ group: DuplicateGroup) -> [Song] {
        group.songIDs.compactMap { id in allSongs.first(where: { $0.id == id }) }
    }
    
    @ViewBuilder
    private func duplicateSection(group: DuplicateGroup) -> some View {
        let songs = songsForGroup(group)
        if songs.count >= 2 {
            Section {
                ForEach(songs, id: \.id) { song in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.url.lastPathComponent)
                            .font(.subheadline)
                        Text(song.album)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("\(group.title) — \(group.artist)")
                    .font(.subheadline.bold())
            } footer: {
                Text("\(songs.count) copies")
                    .font(.caption)
            }
        }
    }
}

// MARK: - Listening stats (Wrapped-style)

private struct TopSongRow: Identifiable {
    var id: URL { url }
    let url: URL
    let title: String
    let artist: String
    let playCount: Int
}

private struct TopArtistRow: Identifiable {
    var id: String { artist }
    let artist: String
    let playCount: Int
}

private let listeningStatsMonthFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM"
    return f
}()

struct ListeningStatsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlayRecord.date, order: .reverse) private var allRecords: [PlayRecord]
    
    private var calendar: Calendar { Calendar.current }
    private var now: Date { Date() }
    private var currentMonthName: String { listeningStatsMonthFormatter.string(from: now) }
    private var currentYear: Int { calendar.component(.year, from: now) }
    private var startOfCurrentYear: Date {
        calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
    }
    private var thirtyDaysAgo: Date {
        calendar.date(byAdding: .day, value: -30, to: now) ?? now
    }
    
    private var recordsThisMonth: [PlayRecord] {
        allRecords.filter { $0.date >= thirtyDaysAgo }
    }
    private var recordsThisYear: [PlayRecord] {
        allRecords.filter { $0.date >= startOfCurrentYear }
    }
    
    private func topSongs(from records: [PlayRecord], limit: Int = 10) -> [TopSongRow] {
        let grouped = Dictionary(grouping: records) { $0.songURL }
        return grouped.map { url, arr in
            let first = arr[0]
            return TopSongRow(url: url, title: first.songTitle, artist: first.songArtist, playCount: arr.count)
        }
        .sorted { $0.playCount > $1.playCount }
        .prefix(limit)
        .map { $0 }
    }
    
    private func topArtists(from records: [PlayRecord], limit: Int = 10) -> [TopArtistRow] {
        let grouped = Dictionary(grouping: records) { $0.songArtist }
        return grouped.map { artist, arr in TopArtistRow(artist: artist, playCount: arr.count) }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }
    
    var body: some View {
        List {
            Section {
                topSongsPanel
            } header: {
                Text("Top Songs")
            }
            
            Section {
                topArtistsPanel
            } header: {
                Text("Top Artists")
            }
            
            Section {
                NavigationLink {
                    PastListeningPeriodsView()
                } label: {
                    Label("Past listening stats", systemImage: "calendar.badge.clock")
                }
                NavigationLink {
                    LifetimeStatsView()
                } label: {
                    Label("Lifetime stats", systemImage: "infinity")
                }
            } header: {
                Text("History")
            } footer: {
                Text("Past listening stats shows months and years that have data. Lifetime stats shows top 50 songs and artists of all time.")
            }
        }
        .navigationTitle("Listening stats")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var topSongsPanel: some View {
        VStack(spacing: 0) {
            // Top half: This Month
            VStack(alignment: .leading, spacing: 6) {
                Text(currentMonthName)
                    .font(.headline)
                Text("This Month")
                    .font(.caption)
                    .foregroundColor(.secondary)
                topSongsContent(records: recordsThisMonth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            
            Divider()
                .padding(.vertical, 4)
            
            // Bottom half: This Year
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: String(currentYear))
                    .font(.headline)
                Text("This Year")
                    .font(.caption)
                    .foregroundColor(.secondary)
                topSongsContent(records: recordsThisYear)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }
    
    private var topArtistsPanel: some View {
        VStack(spacing: 0) {
            // Top half: This Month
            VStack(alignment: .leading, spacing: 6) {
                Text(currentMonthName)
                    .font(.headline)
                Text("This Month")
                    .font(.caption)
                    .foregroundColor(.secondary)
                topArtistsContent(records: recordsThisMonth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            
            Divider()
                .padding(.vertical, 4)
            
            // Bottom half: This Year
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: String(currentYear))
                    .font(.headline)
                Text("This Year")
                    .font(.caption)
                    .foregroundColor(.secondary)
                topArtistsContent(records: recordsThisYear)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }
    
    @ViewBuilder
    private func topSongsContent(records: [PlayRecord]) -> some View {
        let top = topSongs(from: records)
        if top.isEmpty {
            Text("No plays in this period.")
                .foregroundColor(.secondary)
        } else {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.yellow)
                        .frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.subheadline.bold())
                        Text(row.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(row.playCount) plays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    @ViewBuilder
    private func topArtistsContent(records: [PlayRecord]) -> some View {
        let top = topArtists(from: records)
        if top.isEmpty {
            Text("No plays in this period.")
                .foregroundColor(.secondary)
        } else {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.yellow)
                        .frame(width: 24, alignment: .leading)
                    Text(row.artist)
                        .font(.subheadline.bold())
                    Spacer(minLength: 8)
                    Text("\(row.playCount) plays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Past listening stats

private struct PastPeriod: Identifiable {
    var id: String { title + start.timeIntervalSince1970.description }
    let title: String
    let start: Date
    let end: Date
}

private struct PastYearGroup: Identifiable {
    var id: Int { year }
    let year: Int
    let yearStart: Date
    let yearEnd: Date
    let months: [PastPeriod]
}

private let pastPeriodMonthFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM yyyy"
    return f
}()

private let pastPeriodMonthOnlyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM"
    return f
}()

struct PastListeningPeriodsView: View {
    @Query(sort: \PlayRecord.date) private var allRecords: [PlayRecord]
    private var calendar: Calendar { Calendar.current }
    private var now: Date { Date() }
    private var currentYear: Int { calendar.component(.year, from: now) }
    private var currentMonth: Int { calendar.component(.month, from: now) }
    
    private func hasRecords(from start: Date, to end: Date) -> Bool {
        allRecords.contains { $0.date >= start && $0.date < end }
    }
    
    /// Past months in the current year (before current month) that have data.
    private var pastMonthsThisYear: [PastPeriod] {
        guard currentMonth > 1 else { return [] }
        return (1..<currentMonth).compactMap { month -> PastPeriod? in
            guard let start = calendar.date(from: DateComponents(year: currentYear, month: month, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start),
                  hasRecords(from: start, to: end) else { return nil }
            return PastPeriod(title: pastPeriodMonthFormatter.string(from: start), start: start, end: end)
        }
    }
    
    /// Past years (that have data) with full-year range and months that have data. Up to 5 years back.
    private var pastYearGroups: [PastYearGroup] {
        (1...5).compactMap { yearAgo -> PastYearGroup? in
            let year = currentYear - yearAgo
            guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let yearEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)),
                  hasRecords(from: yearStart, to: yearEnd) else { return nil }
            let months: [PastPeriod] = (1...12).compactMap { month -> PastPeriod? in
                guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                      let end = calendar.date(byAdding: .month, value: 1, to: start),
                      hasRecords(from: start, to: end) else { return nil }
                return PastPeriod(title: pastPeriodMonthOnlyFormatter.string(from: start), start: start, end: end)
            }
            return PastYearGroup(year: year, yearStart: yearStart, yearEnd: yearEnd, months: months)
        }
    }
    
    var body: some View {
        List {
            if !pastMonthsThisYear.isEmpty {
                Section {
                    ForEach(pastMonthsThisYear) { period in
                        NavigationLink {
                            PastPeriodStatsView(periodTitle: period.title, start: period.start, end: period.end)
                        } label: {
                            Text(period.title)
                        }
                    }
                } header: {
                    Text("Past months this year")
                } footer: {
                    Text("Months in \(String(currentYear)) that have play data.")
                }
            }
            ForEach(pastYearGroups) { group in
                Section {
                    NavigationLink {
                        PastPeriodStatsView(periodTitle: String(group.year), start: group.yearStart, end: group.yearEnd)
                    } label: {
                        Text(verbatim: String(group.year))
                            .font(.headline)
                    }
                    ForEach(group.months) { period in
                        NavigationLink {
                            PastPeriodStatsView(periodTitle: "\(period.title) \(String(group.year))", start: period.start, end: period.end)
                        } label: {
                            Text(period.title)
                                .padding(.leading, 8)
                        }
                    }
                } header: {
                    Text(verbatim: String(group.year))
                }
            }
        }
        .navigationTitle("Past listening stats")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PastPeriodStatsView: View {
    let periodTitle: String
    let start: Date
    let end: Date
    
    @Query(sort: \PlayRecord.date, order: .reverse) private var allRecords: [PlayRecord]
    
    private var recordsInPeriod: [PlayRecord] {
        allRecords.filter { $0.date >= start && $0.date < end }
    }
    
    private func topSongs(from records: [PlayRecord], limit: Int = 10) -> [TopSongRow] {
        let grouped = Dictionary(grouping: records) { $0.songURL }
        return grouped.map { url, arr in
            let first = arr[0]
            return TopSongRow(url: url, title: first.songTitle, artist: first.songArtist, playCount: arr.count)
        }
        .sorted { $0.playCount > $1.playCount }
        .prefix(limit)
        .map { $0 }
    }
    
    private func topArtists(from records: [PlayRecord], limit: Int = 10) -> [TopArtistRow] {
        let grouped = Dictionary(grouping: records) { $0.songArtist }
        return grouped.map { artist, arr in TopArtistRow(artist: artist, playCount: arr.count) }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }
    
    var body: some View {
        List {
            Section {
                topSongsContent(records: recordsInPeriod)
            } header: {
                Text("Top Songs")
            }
            Section {
                topArtistsContent(records: recordsInPeriod)
            } header: {
                Text("Top Artists")
            }
        }
        .navigationTitle(periodTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private func topSongsContent(records: [PlayRecord]) -> some View {
        let top = topSongs(from: records)
        if top.isEmpty {
            Text("No plays in this period.")
                .foregroundColor(.secondary)
        } else {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.yellow)
                        .frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.subheadline.bold())
                        Text(row.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(row.playCount) plays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    @ViewBuilder
    private func topArtistsContent(records: [PlayRecord]) -> some View {
        let top = topArtists(from: records)
        if top.isEmpty {
            Text("No plays in this period.")
                .foregroundColor(.secondary)
        } else {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.yellow)
                        .frame(width: 24, alignment: .leading)
                    Text(row.artist)
                        .font(.subheadline.bold())
                    Spacer(minLength: 8)
                    Text("\(row.playCount) plays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Lifetime stats

struct LifetimeStatsView: View {
    @Query(sort: \PlayRecord.date) private var allRecords: [PlayRecord]
    
    private func topSongs(from records: [PlayRecord], limit: Int = 50) -> [TopSongRow] {
        let grouped = Dictionary(grouping: records) { $0.songURL }
        return grouped.map { url, arr in
            let first = arr[0]
            return TopSongRow(url: url, title: first.songTitle, artist: first.songArtist, playCount: arr.count)
        }
        .sorted { $0.playCount > $1.playCount }
        .prefix(limit)
        .map { $0 }
    }
    
    private func topArtists(from records: [PlayRecord], limit: Int = 50) -> [TopArtistRow] {
        let grouped = Dictionary(grouping: records) { $0.songArtist }
        return grouped.map { artist, arr in TopArtistRow(artist: artist, playCount: arr.count) }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }
    
    var body: some View {
        List {
            Section {
                lifetimeSongsContent
            } header: {
                Text("Top 50 Songs")
            }
            Section {
                lifetimeArtistsContent
            } header: {
                Text("Top 50 Artists")
            }
        }
        .navigationTitle("Lifetime stats")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private var lifetimeSongsContent: some View {
        let top = topSongs(from: allRecords, limit: 50)
        if top.isEmpty {
            Text("No plays yet.")
                .foregroundColor(.secondary)
        } else {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.yellow)
                        .frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.subheadline.bold())
                        Text(row.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(row.playCount) plays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    @ViewBuilder
    private var lifetimeArtistsContent: some View {
        let top = topArtists(from: allRecords, limit: 50)
        if top.isEmpty {
            Text("No plays yet.")
                .foregroundColor(.secondary)
        } else {
            ForEach(Array(top.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .foregroundColor(.yellow)
                        .frame(width: 28, alignment: .leading)
                    Text(row.artist)
                        .font(.subheadline.bold())
                    Spacer(minLength: 8)
                    Text("\(row.playCount) plays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
