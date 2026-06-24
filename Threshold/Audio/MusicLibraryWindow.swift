//
//  MusicLibraryWindow.swift
//  Threshold
//
//  Standalone library browser window.
//  Opens via the "Open Library" button in the Music tab.
//  Shows songs, playlists (with drill-down to see tracks), and albums
//  for every connected service.
//

import SwiftUI

// MARK: - Library Window ID

extension AppModel {
    /// Window identifier for the library pop-out window.
    static let libraryWindowID = "music-library"
}

// MARK: - Root View

struct MusicLibraryWindow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var selectedServiceID: String?
    @State private var scope: LibScope = .songs
    @State private var search = ""
    @State private var shuffle = false

    /// Playlist the user tapped to drill-down into.
    @State private var expandedPlaylist: UnifiedPlaylist?
    @State private var playlistTracks: [UnifiedTrack] = []
    @State private var isLoadingTracks = false

    private enum LibScope: String, CaseIterable {
        case songs = "Songs"
        case playlists = "Playlists"
        case albums = "Albums"
    }

    // ── Derived state ─────────────────────────────────────────────────

    private var music: MusicService { appModel.musicService }

    private var activeID: String? {
        selectedServiceID ?? music.activeProvider?.serviceID
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // ── Body ──────────────────────────────────────────────────────────

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolbar
                Divider()
                content
            }
            .navigationTitle("Music Library")
            #if os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // ── Toolbar (service picker, scope, search) ─────────────────────

    private var toolbar: some View {
        VStack(spacing: 8) {
            // Service picker
            if music.connectedProviders.count > 1 {
                Picker("Service", selection: Binding(
                    get: { activeID ?? "" },
                    set: { selectedServiceID = $0 }
                )) {
                    ForEach(music.connectedProviders, id: \.serviceID) { p in
                        Label(p.displayName, systemImage: p.iconName)
                            .tag(p.serviceID)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                // Scope picker
                Picker("", selection: $scope) {
                    ForEach(LibScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: scope) { _, _ in
                    // Clear playlist drill-down when switching scope
                    expandedPlaylist = nil
                    playlistTracks = []
                    isLoadingTracks = false
                }

                if scope != .songs {
                    Toggle(isOn: $shuffle) {
                        Image(systemName: AppIcons.shuffle)
                            .font(.caption)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                }

                Button {
                    music.refreshLibrary(for: activeID)
                } label: {
                    Image(systemName: AppIcons.arrowClockwise)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // ── Content ──────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if music.isLibraryLoading(for: activeID) {
            Spacer()
            ProgressView("Loading library…")
            Spacer()
        } else if let err = music.libraryError(for: activeID) {
            Spacer()
            Text(err).foregroundStyle(.red).padding()
            Spacer()
        } else {
            switch scope {
            case .songs:
                songsList
            case .playlists:
                playlistsContent
            case .albums:
                albumsList
            }
        }
    }

    // ── Songs ────────────────────────────────────────────────────────

    private var songsList: some View {
        let tracks = filteredSongs
        return List(tracks, id: \.id) { track in
            trackRow(track)
        }
        .listStyle(.plain)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("No Songs", systemImage: AppIcons.musicNote, description: Text("No songs match your search."))
            }
        }
    }

    // ── Playlists (with drill-down) ──────────────────────────────────

    @ViewBuilder
    private var playlistsContent: some View {
        if let playlist = expandedPlaylist {
            // Drill-down: show tracks inside this playlist
            playlistDetail(playlist)
        } else {
            // Top-level playlist list
            playlistsList
        }
    }

    private var playlistsList: some View {
        let playlists = filteredPlaylists
        return List(playlists, id: \.id) { pl in
            Button {
                drillIntoPlaylist(pl)
            } label: {
                playlistRow(pl)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .overlay {
            if playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: AppIcons.musicNoteList, description: Text("No playlists match your search."))
            }
        }
    }

    private func playlistDetail(_ playlist: UnifiedPlaylist) -> some View {
        VStack(spacing: 0) {
            // Back bar
            HStack {
                Button {
                    withMotionSensitiveAnimation {
                        expandedPlaylist = nil
                        playlistTracks = []
                        isLoadingTracks = false
                    }
                } label: {
                    Label("Playlists", systemImage: AppIcons.chevronLeft)
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(playlist.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Button {
                    music.playPlaylist(playlist, shuffle: shuffle)
                } label: {
                    Label("Play All", systemImage: shuffle ? AppIcons.shuffle : AppIcons.playFill)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if isLoadingTracks {
                Spacer()
                ProgressView("Loading tracks…")
                Spacer()
            } else {
                List(playlistTracks, id: \.id) { track in
                    trackRow(track)
                }
                .listStyle(.plain)
                .overlay {
                    if playlistTracks.isEmpty {
                        ContentUnavailableView("Empty Playlist", systemImage: AppIcons.musicNote, description: Text("This playlist has no tracks."))
                    }
                }
            }
        }
        .task(id: playlist.id) {
            await loadTracks(for: playlist)
        }
    }

    private func drillIntoPlaylist(_ playlist: UnifiedPlaylist) {
        expandedPlaylist = playlist
        isLoadingTracks = true
        playlistTracks = []
    }

    private func loadTracks(for playlist: UnifiedPlaylist) async {
        guard expandedPlaylist?.id == playlist.id else { return }

        guard let provider = music.provider(for: playlist.serviceID) else {
            isLoadingTracks = false
            return
        }

        let tracks = await provider.fetchPlaylistTracks(playlist)
        guard !Task.isCancelled, expandedPlaylist?.id == playlist.id else { return }

        playlistTracks = tracks
        isLoadingTracks = false
    }

    private func withMotionSensitiveAnimation(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation {
                updates()
            }
        }
    }

    // ── Albums ───────────────────────────────────────────────────────

    private var albumsList: some View {
        let albums = filteredAlbums
        return List(albums, id: \.id) { album in
            Button { music.playAlbum(album, shuffle: shuffle) } label: {
                albumRow(album)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .overlay {
            if albums.isEmpty {
                ContentUnavailableView("No Albums", systemImage: AppIcons.squareStack, description: Text("No albums match your search."))
            }
        }
    }

    // ── Row Views ────────────────────────────────────────────────────

    private func trackRow(_ track: UnifiedTrack) -> some View {
        Button { music.playSong(track) } label: {
            HStack(spacing: 10) {
                artworkView(url: track.artworkURL, fallback: "music.note")
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if track.durationSeconds > 0 {
                    Text(track.durationString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ pl: UnifiedPlaylist) -> some View {
        HStack(spacing: 10) {
            artworkView(url: pl.artworkURL, fallback: "music.note.list")
            VStack(alignment: .leading, spacing: 2) {
                Text(pl.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let owner = pl.ownerName {
                        Text(owner)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(pl.trackCount) songs")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: AppIcons.chevronRight)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func albumRow(_ album: UnifiedAlbum) -> some View {
        HStack(spacing: 10) {
            artworkView(url: album.artworkURL, fallback: "square.stack")
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(album.trackCount) songs")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // ── Artwork helper ───────────────────────────────────────────────

    private func artworkView(url: URL?, fallback: String) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholderIcon(fallback)
                }
            } else {
                placeholderIcon(fallback)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func placeholderIcon(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .overlay(
                Image(systemName: name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
    }

    // ── Filtering ────────────────────────────────────────────────────

    private var filteredSongs: [UnifiedTrack] {
        let all = music.librarySongs(for: activeID)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }

    private var filteredPlaylists: [UnifiedPlaylist] {
        let all = music.libraryPlaylists(for: activeID)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(query) }
    }

    private var filteredAlbums: [UnifiedAlbum] {
        let all = music.libraryAlbums(for: activeID)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query) }
    }
}
