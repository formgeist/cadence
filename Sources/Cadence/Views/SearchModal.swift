import SwiftUI
import CadenceCore

/// The command-palette search surface — Spotify/Claude's own pattern rather
/// than a dropdown hanging off the title bar's field. `SearchTrigger` in
/// `TitleBarView` opens it; this view owns the text field, the two states
/// (suggestions before typing, results after), and all keyboard handling.
/// Presented whenever `AppModel.isSearching` is true — see `RootView`.
struct SearchModal: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    // Optional so the snapshot, a11y and benchmark harnesses can host this
    // view without one — same reasoning as `TextEntryMonitor`'s environment.
    @Environment(SearchFocusRequester.self) private var focusRequester: SearchFocusRequester?
    @FocusState private var isFocused: Bool
    /// The local key monitor that answers arrow keys while the modal is up
    /// — see the note on `AppModel.moveSearchHighlight`.
    @State private var arrowKeyMonitor: Any?
    /// The row the pointer is over, in the same flat order `resolve(_:)`
    /// walks. Separate from keyboard's `searchHighlightedIndex`: hovering
    /// doesn't move the keyboard selection, and ⌘↵ prefers whichever row is
    /// under the pointer, falling back to the keyboard highlight when
    /// nothing is hovered.
    @State private var hoveredIndex: Int?

    var body: some View {
        @Bindable var model = model

        ZStack {
            // The scrim: dims the whole window and closes the modal on a
            // click outside the card, same as Spotify/Claude's own palette.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.endSearch() }
                .accessibilityHidden(true)

            card
                .frame(maxWidth: Tokens.Layout.searchModalWidth)
                .padding(.horizontal, Tokens.Space.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, Tokens.Layout.searchModalTopInset)
        .onAppear {
            isFocused = true
            if arrowKeyMonitor == nil {
                // A `Binding`, not `self`: this closure outlives any one
                // `body` evaluation, and capturing the view struct itself
                // here would pin a stale copy — the arrow-key handling below
                // avoids the same trap by only ever touching `model`.
                let hovered = $hoveredIndex
                arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model, weak playback] event in
                    guard let model else { return event }
                    // ⌘↵ plays the hovered row directly — or the keyboard
                    // highlight when nothing is hovered — regardless of what
                    // a plain Return there would do. Plain Return is answered
                    // by the text field's own `.onSubmit`, so only the ⌘
                    // variant needs catching here.
                    if event.keyCode == 36, event.modifierFlags.contains(.command) {
                        if let playback, let index = hovered.wrappedValue ?? model.searchEffectiveHighlight {
                            Self.play(resultAt: index, model: model, playback: playback)
                        }
                        return nil
                    }
                    guard let direction = GridNavigation.Direction(keyCode: event.keyCode),
                          direction == .up || direction == .down else {
                        return event
                    }
                    model.moveSearchHighlight(direction)
                    return nil
                }
            }
        }
        .onDisappear {
            if let arrowKeyMonitor { NSEvent.removeMonitor(arrowKeyMonitor) }
            arrowKeyMonitor = nil
        }
        .onChange(of: focusRequester?.token) { _, _ in
            isFocused = true
        }
        .onExitCommand {
            model.endSearch()
        }
    }

    private var card: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            header
            hairline
            content
            hairline
            footer
        }
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .strokeBorder(Tokens.Palette.popoverBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Tokens.Palette.popoverBorder)
            .frame(height: 1)
    }

    private var header: some View {
        @Bindable var model = model

        return HStack(spacing: Tokens.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: 0x7A7A85))
                .accessibilityHidden(true)

            TextField("Search artists, albums, tracks", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(Tokens.Typography.sans(17, .medium))
                .foregroundStyle(Color(hex: 0xF0F0F5))
                .focused($isFocused)
                .textEntryFocus(isFocused)
                .onSubmit {
                    if let highlight = model.searchEffectiveHighlight {
                        activate(highlight)
                    } else {
                        model.commitCurrentSearch()
                    }
                }
                .accessibilityLabel("Search library")

            Button {
                model.endSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: 0x7A7A85))
            }
            .plainControl()
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.l)
    }

    @ViewBuilder
    private var contentBody: some View {
        if model.searchText.isEmpty {
            if model.recentlyPlayed.isEmpty && model.recentSearches.isEmpty {
                emptyState(message: "Search your library by artist, album, or track")
            } else {
                suggestions
            }
            // No query has answered yet and there's nothing left over from a
            // moment ago to show in the meantime: wait rather than claim "no
            // results" about a query that hasn't run — see #72.
        } else if model.searchResults.isEmpty && model.isSearchPending {
            Color.clear.frame(height: 1)
        } else if model.searchResults.isEmpty {
            emptyState(message: "No results for “\(model.searchText)”")
        } else {
            results
        }
    }

    private var content: some View {
        ScrollView { contentBody }
            .scrollIndicators(.hidden)
            .frame(maxHeight: Tokens.Layout.searchModalMaxHeight)
    }

    private func emptyState(message: String) -> some View {
        Text(message)
            .font(Tokens.Typography.sans(13.5, .semibold))
            .foregroundStyle(Color(hex: 0x8A8A94))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.xxl)
    }

    /// ⌘↵ needs a row to act on — true whenever there's anything to select at
    /// all, the empty-state suggestions (recently played, recent searches)
    /// included: a recently played row plays just as it would under ↵.
    private var canPlayDirectly: Bool {
        model.searchNavigableCount > 0
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.l) {
            hint("Select", ["↑", "↓"])
            hint("Open", ["Return"])
            if canPlayDirectly {
                hint("Play", ["⌘", "Return"])
            }
            hint("Close", ["Esc"])
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.m)
    }

    /// A label followed by its keys, each in its own bordered cap — one box
    /// per physical key, the way a keyboard shortcut reads on a real
    /// keyboard, rather than one pill spelling the whole combo out.
    private func hint(_ label: String, _ keys: [String]) -> some View {
        HStack(spacing: Tokens.Space.xs) {
            Text(label)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textMuted)
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(Tokens.Typography.mono(10.5, .medium))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .frame(minWidth: 16)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.thumb, style: .continuous)
                                .strokeBorder(Tokens.Palette.borderStrong, lineWidth: 1)
                        }
                }
            }
        }
    }

    // MARK: - Suggestions (before typing)

    /// What the modal shows the moment it opens, before anything has been
    /// typed — issue #72: recently played tracks and recent searches, if
    /// there are any.
    private var suggestions: some View {
        let recentSearchesStart = model.recentlyPlayed.count
        let highlighted = model.searchEffectiveHighlight

        return VStack(alignment: .leading, spacing: 0) {
            if !model.recentlyPlayed.isEmpty {
                modalGroup("Recently Played", model.recentlyPlayed.map { track in
                    SearchRow(title: track.title,
                              subtitle: track.artist,
                              trailing: DurationFormat.clock(track.duration),
                              artworkID: track.artworkID,
                              action: { play(track) })
                }, startIndex: 0, highlightedIndex: highlighted, onHover: setHover)
            }
            if !model.recentSearches.isEmpty {
                modalGroup("Recent Searches", model.recentSearches.map { query in
                    SearchRow(title: query, subtitle: "", trailing: "",
                              icon: "magnifyingglass",
                              action: { model.searchText = query })
                }, startIndex: recentSearchesStart, highlightedIndex: highlighted, onHover: setHover)
            }
        }
        .padding(.vertical, Tokens.Space.s)
    }

    // MARK: - Results (while typing)

    private var results: some View {
        let searchResults = model.searchResults
        let topHitCount = searchResults.topHit != nil ? 1 : 0
        let artistsStart = topHitCount
        let albumsStart = artistsStart + searchResults.artists.count
        let tracksStart = albumsStart + searchResults.albums.count
        let highlighted = model.searchEffectiveHighlight

        return VStack(alignment: .leading, spacing: 0) {
            if let topHit = searchResults.topHit {
                TopHitRow(album: topHit, isHighlighted: highlighted == 0,
                          action: { open(topHit) }, onHover: { setHover(0, $0) })
            }
            if !searchResults.artists.isEmpty {
                modalGroup("Artists", searchResults.artists.map { artist in
                    SearchRow(title: artist.name,
                              subtitle: artist.albumCount == 1
                                  ? "1 album" : "\(artist.albumCount) albums",
                              trailing: artist.formats.first ?? "",
                              isRound: true,
                              artworkID: model.artworkID(forArtist: artist.name),
                              action: { open(artist) })
                }, startIndex: artistsStart, highlightedIndex: highlighted, onHover: setHover)
            }
            if !searchResults.albums.isEmpty {
                modalGroup("Albums", searchResults.albums.map { album in
                    SearchRow(title: album.title,
                              subtitle: [album.albumArtist, album.year.map(String.init)]
                                  .compactMap { $0 }.joined(separator: " · "),
                              trailing: album.dominantFormat?.shortDescription ?? "",
                              artworkID: album.artworkID,
                              action: { open(album) })
                }, startIndex: albumsStart, highlightedIndex: highlighted, onHover: setHover)
            }
            if !searchResults.tracks.isEmpty {
                modalGroup("Tracks", searchResults.tracks.map { track in
                    SearchRow(title: track.title,
                              subtitle: track.albumTitle,
                              trailing: DurationFormat.clock(track.duration),
                              artworkID: track.artworkID,
                              action: { play(track) })
                }, startIndex: tracksStart, highlightedIndex: highlighted, onHover: setHover)
            }
        }
        .padding(.vertical, Tokens.Space.s)
    }

    // MARK: - Activation

    /// Runs whatever a click on row `index` would — same flat order as
    /// `model.searchNavigableCount`.
    private func activate(_ index: Int) {
        Self.activate(resultAt: index, model: model, playback: playback)
    }

    /// What one flat search-result index resolves to.
    private enum ResolvedResult {
        case recentlyPlayed(Track)
        case recentSearch(String)
        case topHit(Album)
        case artist(Artist)
        case album(Album)
        case track(Track)
    }

    /// What row `index` actually is, in the same flat order
    /// `model.searchNavigableCount` walks: recently played then recent
    /// searches before any text, or top hit then artists then albums then
    /// tracks once there's a query. This and everything below it that acts on
    /// the result are `static func`s taking `model` and `playback`
    /// explicitly, rather than instance methods reading them from `self` —
    /// the ⌘↵ key monitor in `onAppear` outlives any one `body` evaluation
    /// and can only safely capture the class-typed environment values, never
    /// the view struct itself.
    private static func resolve(_ index: Int, model: AppModel) -> ResolvedResult? {
        guard !model.searchText.isEmpty else {
            let recentlyPlayed = model.recentlyPlayed
            if index < recentlyPlayed.count { return .recentlyPlayed(recentlyPlayed[index]) }
            let searchIndex = index - recentlyPlayed.count
            guard model.recentSearches.indices.contains(searchIndex) else { return nil }
            return .recentSearch(model.recentSearches[searchIndex])
        }

        let searchResults = model.searchResults
        var offset = 0
        if let topHit = searchResults.topHit {
            if index == offset { return .topHit(topHit) }
            offset += 1
        }
        if index < offset + searchResults.artists.count {
            return .artist(searchResults.artists[index - offset])
        }
        offset += searchResults.artists.count
        if index < offset + searchResults.albums.count {
            return .album(searchResults.albums[index - offset])
        }
        offset += searchResults.albums.count
        if index < offset + searchResults.tracks.count {
            return .track(searchResults.tracks[index - offset])
        }
        return nil
    }

    /// The default action for row `index` — open for an artist or album,
    /// play for a track, fill the field for a recent search.
    private static func activate(resultAt index: Int, model: AppModel, playback: PlaybackController) {
        switch resolve(index, model: model) {
        case .recentlyPlayed(let track), .track(let track):
            play(track, model: model, playback: playback)
        case .recentSearch(let query):
            model.searchText = query
        case .topHit(let album), .album(let album):
            open(album, model: model)
        case .artist(let artist):
            open(artist, model: model)
        case nil:
            break
        }
    }

    /// ⌘↵'s action for row `index` — play, always, rather than open: an
    /// artist plays its earliest album from the top, an album plays from its
    /// first track. A recent-search row has nothing to play, so ⌘↵ there is a
    /// no-op.
    private static func play(resultAt index: Int, model: AppModel, playback: PlaybackController) {
        switch resolve(index, model: model) {
        case .recentlyPlayed(let track), .track(let track):
            play(track, model: model, playback: playback)
        case .topHit(let album), .album(let album):
            model.commitCurrentSearch()
            playback.play(album)
            model.endSearch()
        case .artist(let artist):
            let tracks = model.albums(byArtist: artist.name).flatMap { $0.discs.flatMap(\.tracks) }
            guard let first = tracks.first else { return }
            model.commitCurrentSearch()
            playback.play(first, in: tracks)
            model.endSearch()
        case .recentSearch, nil:
            break
        }
    }

    private static func play(_ track: Track, model: AppModel, playback: PlaybackController) {
        guard let album = model.album(for: track.albumKey) else { return }
        // Only a real search's pick is worth remembering as a recent search
        // — a recently-played row picked straight from the empty state isn't
        // a search at all.
        if !model.searchText.isEmpty { model.commitCurrentSearch() }
        playback.play(track, in: album.discs.flatMap(\.tracks))
        model.endSearch()
    }

    private static func open(_ album: Album, model: AppModel) {
        model.commitCurrentSearch()
        model.show(.album(album.key))
        model.endSearch()
    }

    private static func open(_ artist: Artist, model: AppModel) {
        model.commitCurrentSearch()
        model.show(.artist(artist.name))
        model.endSearch()
    }

    private func play(_ track: Track) {
        Self.play(track, model: model, playback: playback)
    }

    private func open(_ album: Album) {
        Self.open(album, model: model)
    }

    private func open(_ artist: Artist) {
        Self.open(artist, model: model)
    }

    /// Updates `hoveredIndex` for row `index`. Written so a pointer moving
    /// from one row straight to the next can't clobber the new row's
    /// "entered" with the old row's "exited" — AppKit doesn't guarantee which
    /// fires first — by only clearing when `index` is still the current one.
    private func setHover(_ index: Int, _ isHovering: Bool) {
        if isHovering {
            hoveredIndex = index
        } else if hoveredIndex == index {
            hoveredIndex = nil
        }
    }
}

// MARK: - Shared row

/// One row in a titled group — an artist, album, track, recent play, or
/// recent search.
private struct SearchRow: Identifiable {
    var id = UUID()
    var title: String
    var subtitle: String
    var trailing: String
    var isRound: Bool = false
    /// Real artwork for a row that has some, e.g. a recently played track. A
    /// search result row leaves this nil — see `ArtworkView`'s stripe
    /// placeholder below.
    var artworkID: Artwork.ID? = nil
    /// An SF Symbol instead of `ArtworkView`, for a row with no artwork of
    /// its own — a recent search term, say.
    var icon: String? = nil
    var action: () -> Void
}

@MainActor
@ViewBuilder
private func modalGroup(_ label: String, _ rows: [SearchRow],
                        startIndex: Int, highlightedIndex: Int?,
                        onHover: @escaping (Int, Bool) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        SectionLabel(label, size: 11)
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.top, Tokens.Space.l)
            .padding(.bottom, Tokens.Space.s)
        ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
            let index = startIndex + offset
            let isHighlighted = highlightedIndex == index
            Button(action: row.action) {
                HStack(spacing: Tokens.Space.m) {
                    if let icon = row.icon {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(hex: 0x7A7A85))
                            .frame(width: 40, height: 40)
                    } else {
                        ArtworkView(artworkID: row.artworkID,
                                    cornerRadius: Tokens.Radius.thumb,
                                    isCircular: row.isRound,
                                    stripe: 5,
                                    displaySize: 52)
                            .frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(Tokens.Typography.sans(15, .semibold))
                            .foregroundStyle(Color(hex: 0xDCDCE3))
                            .lineLimit(1)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(Tokens.Typography.sans(12.5, .medium))
                                .foregroundStyle(Color(hex: 0x7A7A84))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Tokens.Space.s)
                    Text(row.trailing)
                        .font(Tokens.Typography.mono(11.5))
                        .foregroundStyle(Tokens.Palette.textFaint)
                }
                .padding(.horizontal, Tokens.Space.l)
                .padding(.vertical, Tokens.Space.s + 2)
                .hoverHighlight(isActive: isHighlighted, radius: Tokens.Radius.control,
                                hoverColor: Color(hex: 0x1F1F26),
                                activeColor: Color(hex: 0x1F1F26))
                .padding(.horizontal, Tokens.Space.s)
            }
            .plainControl()
            .onHover { onHover(index, $0) }
        }
    }
}

private struct TopHitRow: View {
    var album: Album
    /// The row's fill is already the same tone the rest of the modal uses
    /// for hover, so a plain background swap wouldn't read as "selected"
    /// here the way it does for `modalGroup`'s rows — this needs its own
    /// ring, same idea as `keyboardFocusRing` elsewhere in the app.
    var isHighlighted: Bool = false
    var action: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.l) {
                ArtworkView(artworkID: album.artworkID, cornerRadius: Tokens.Radius.card,
                            displaySize: 128)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(Tokens.Typography.sans(17, .bold))
                        .foregroundStyle(Color(hex: 0xF1F1F5))
                        .lineLimit(1)
                    Text(["Album", album.albumArtist, album.year.map(String.init)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Tokens.Typography.sans(13.5, .medium))
                        .foregroundStyle(Color(hex: 0x7C7C86))
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.s)
                Text("TOP HIT")
                    .font(Tokens.Typography.mono(10.5, .medium))
                    .tracking(0.8)
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.vertical, Tokens.Space.m)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(Color(hex: 0x1F1F26))
            }
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                        .strokeBorder(Tokens.Palette.accent, lineWidth: 1.5)
                }
            }
            .padding(.horizontal, Tokens.Space.s)
            .padding(.top, Tokens.Space.s)
        }
        .plainControl()
        .onHover(perform: onHover)
    }
}
