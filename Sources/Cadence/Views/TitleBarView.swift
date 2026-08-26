import SwiftUI
import CadenceCore

/// The window's own chrome. The mock paints three traffic-light circles; a
/// native window with `.hiddenTitleBar` already has real ones, so this reserves
/// their space instead of drawing imitations.
struct TitleBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        @Bindable var model = model

        HStack(spacing: Tokens.Space.l) {
            Color.clear.frame(width: Tokens.Layout.trafficLightInset, height: 1)

            HStack(spacing: Tokens.Space.xs) {
                NavigationChevron(direction: .backward, isEnabled: model.canGoBack) {
                    model.goBack()
                }
                NavigationChevron(direction: .forward, isEnabled: false) {}
            }

            SearchField()
                .frame(maxWidth: Tokens.Layout.searchFieldMaxWidth)
                .frame(maxWidth: .infinity)
                .zIndex(30)

            // Balances the chevrons so the field sits optically centred.
            Color.clear.frame(width: 92, height: 1)
        }
        .padding(.horizontal, Tokens.Space.l)
        .frame(height: Tokens.Layout.titleBarHeight)
        // The hairline is a *background*, not an overlay: the search
        // suggestions start three points above the header's bottom edge, and
        // an overlay would draw this line straight across their top corners.
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: 0x1F1F24))
                .frame(height: 1)
        }
        .background(Tokens.Palette.chrome)
    }
}

private struct NavigationChevron: View {
    enum Direction { case backward, forward }

    var direction: Direction
    var isEnabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .backward ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled
                                 ? (isHovering ? Color(hex: 0xC9C9D2) : Color(hex: 0x6E6E78))
                                 : Color(hex: 0x43434C))
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(isEnabled && isHovering ? Color(hex: 0x1E1E24) : .clear)
                }
        }
        .plainControl()
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(direction == .backward ? "Back" : "Forward")
    }
}

// MARK: - Search

struct SearchField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.rendersSearchFocused) private var rendersFocused
    // Optional so the snapshot, a11y and benchmark harnesses can host this
    // view without one — same reasoning as `TextEntryMonitor`'s environment.
    @Environment(SearchFocusRequester.self) private var focusRequester: SearchFocusRequester?
    @FocusState private var isFocused: Bool
    /// False for the one tick between the view appearing and the `onAppear`
    /// below correcting AppKit's ambient initial-focus assignment. Without
    /// this, that correction is still invisible to the *user* (`isFocused`
    /// never settles on `true` for a redraw the user perceives) but the
    /// popover can still flash into existence for that one frame before it
    /// does — see #72.
    @State private var hasSettled = false
    /// The same one-tick shield as `hasSettled`, scoped to navigation instead
    /// of launch: true from the moment `model.screen` changes until the
    /// deferred check below has had its say. Without it, an ambient
    /// reassignment that lands in the same tick as the navigation would still
    /// flash the popover in for a frame before that check clears it.
    @State private var isSettlingAfterNavigation = false

    /// What the field *looks* like: focused for real, or drawn that way for a
    /// snapshot.
    private var isActive: Bool {
        hasSettled && !isSettlingAfterNavigation && (isFocused || rendersFocused)
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s + 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x7A7A85))
                    .accessibilityHidden(true)

                TextField("Search artists, albums, tracks", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundStyle(Color(hex: 0xF0F0F5))
                    .focused($isFocused)
                    .textEntryFocus(isFocused)
                    .onSubmit { model.commitCurrentSearch(); isFocused = false }
                    .accessibilityLabel("Search library")

                if !model.searchText.isEmpty {
                    Button {
                        model.endSearch()
                        isFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0x7A7A85))
                    }
                    .plainControl()
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(isActive
                          ? Tokens.Palette.fieldFocusBackground
                          : Tokens.Palette.fieldBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(isActive
                                  ? Tokens.Palette.fieldFocusBorder
                                  : Tokens.Palette.fieldBorder, lineWidth: 1)
            }
        }
        .overlay(alignment: .top) {
            if isActive {
                if model.searchText.isEmpty {
                    // Nothing played or searched yet: the placeholder
                    // already says what to do, so there's nothing this
                    // popover would add.
                    if !model.recentlyPlayed.isEmpty || !model.recentSearches.isEmpty {
                        SearchSuggestionsPopover(onPick: { isFocused = false })
                            .offset(y: 38)
                    }
                    // No query has answered yet and there's nothing left
                    // over from a moment ago to show in the meantime: wait
                    // rather than claim "no results" about a query that
                    // hasn't run — see #72. Once either turns false — a
                    // stale result to hold onto, or the debounce settling —
                    // this reads the same as the branch above.
                } else if !model.searchResults.isEmpty || !model.isSearchPending {
                    SearchResultsPopover(onPick: { isFocused = false })
                        .offset(y: 38)
                }
            }
        }
        .onAppear {
            // AppKit sometimes hands a freshly-created window's initial
            // keyboard focus to the first focusable control it finds — this
            // field, ahead of anything the user did — which shows the
            // suggestions popover unasked for at launch. `isActive` stays
            // held off via `hasSettled` for this same one tick, so that
            // ambient assignment never reaches the screen at all — clearing
            // `isFocused` alone still lets the popover flash in for the
            // frame before the clear lands. Compared against the token
            // taken *before* the wait rather than assumed stale, so a
            // genuine ⌘K in that same tick is never swallowed: if the token
            // has already moved on, something real asked for focus, and
            // this leaves it alone.
            let tokenAtLaunch = focusRequester?.token
            DispatchQueue.main.async {
                if focusRequester?.token == tokenAtLaunch {
                    isFocused = false
                }
                hasSettled = true
            }
        }
        .onChange(of: isFocused) { _, focused in
            model.isSearching = focused
        }
        .onChange(of: focusRequester?.token) { _, _ in
            isFocused = true
        }
        // Clicking an artist or album link inside a focused list — the track
        // list's own click-to-select claims keyboard focus first, same as
        // the search field does — removes that list from the screen the
        // instant navigation lands. AppKit reassigns the keyboard to
        // whatever key view it finds next only once it actually tears down
        // the old view, which lags a tick behind the `screen` change itself
        // — clearing `isFocused` synchronously here just loses the race and
        // gets overwritten right back. Deferred the same one tick as the
        // launch fix above, and guarded by the same token comparison so a
        // genuine ⌘K landing in that tick is never swallowed; `isActive`
        // stays held off for that tick too, the same reason `hasSettled` does
        // at launch.
        .onChange(of: model.screen) { _, _ in
            isSettlingAfterNavigation = true
            let tokenAtNavigation = focusRequester?.token
            DispatchQueue.main.async {
                if focusRequester?.token == tokenAtNavigation {
                    isFocused = false
                }
                isSettlingAfterNavigation = false
            }
        }
        .onExitCommand {
            model.endSearch()
            isFocused = false
        }
    }
}

private struct SearchResultsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var onPick: () -> Void

    var body: some View {
        let results = model.searchResults

        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text("No results for “\(model.searchText)”")
                    .font(Tokens.Typography.sans(11.5, .semibold))
                    .foregroundStyle(Color(hex: 0x8A8A94))
                    .padding(.horizontal, Tokens.Space.xl)
                    .padding(.vertical, 14)
            } else {
                if let topHit = results.topHit {
                    TopHitRow(album: topHit) { open(topHit) }
                }
                if !results.artists.isEmpty {
                    popoverGroup("Artists", results.artists.map { artist in
                        PopoverRow(title: artist.name,
                                   subtitle: artist.albumCount == 1
                                       ? "1 album" : "\(artist.albumCount) albums",
                                   trailing: artist.formats.first ?? "",
                                   isRound: true,
                                   artworkID: model.artworkID(forArtist: artist.name),
                                   action: { open(artist) })
                    })
                }
                if !results.albums.isEmpty {
                    popoverGroup("Albums", results.albums.map { album in
                        PopoverRow(title: album.title,
                                   subtitle: [album.albumArtist, album.year.map(String.init)]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   trailing: album.dominantFormat?.shortDescription ?? "",
                                   isRound: false,
                                   artworkID: album.artworkID,
                                   action: { open(album) })
                    })
                }
                if !results.tracks.isEmpty {
                    popoverGroup("Tracks", results.tracks.map { track in
                        PopoverRow(title: track.title,
                                   subtitle: track.albumTitle,
                                   trailing: DurationFormat.clock(track.duration),
                                   isRound: false,
                                   artworkID: track.artworkID,
                                   action: { play(track) })
                    })
                }

                Divider().overlay(Color(hex: 0x24242B)).padding(.top, Tokens.Space.s)
                HStack {
                    Text("See all results for “\(model.searchText)”")
                        .font(Tokens.Typography.sans(11.5, .semibold))
                        .foregroundStyle(Color(hex: 0x8A8A94))
                    Spacer()
                    Text("↵")
                        .font(Tokens.Typography.mono(10))
                        .foregroundStyle(Tokens.Palette.textFaint)
                }
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.vertical, 9)
            }
        }
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .strokeBorder(Tokens.Palette.popoverBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
    }

    private func open(_ album: Album) {
        model.commitCurrentSearch()
        model.show(.album(album.key))
        model.endSearch()
        onPick()
    }

    private func open(_ artist: Artist) {
        model.commitCurrentSearch()
        model.show(.artist(artist.name))
        model.endSearch()
        onPick()
    }

    private func play(_ track: Track) {
        guard let album = model.album(for: track.albumKey) else { return }
        model.commitCurrentSearch()
        playback.play(track, in: album.discs.flatMap(\.tracks))
        model.endSearch()
        onPick()
    }
}

/// What the popover shows the moment the field is focused, before anything
/// has been typed — issue #72: recently played tracks and recent searches,
/// if there are any. `SearchField` only shows this once one of those groups
/// is non-empty; an empty, freshly-focused search bar with no history yet
/// still shows nothing, same as before #72 — its own placeholder text
/// already says what to do.
private struct SearchSuggestionsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var onPick: () -> Void

    var body: some View {
        @Bindable var model = model

        // The caller only shows this popover once there is at least one
        // group to put in it — an empty field with no history yet already
        // says what to do via its own placeholder text.
        VStack(alignment: .leading, spacing: 0) {
            if !model.recentlyPlayed.isEmpty {
                popoverGroup("Recently Played", model.recentlyPlayed.map { track in
                    PopoverRow(title: track.title,
                               subtitle: track.artist,
                               trailing: DurationFormat.clock(track.duration),
                               artworkID: track.artworkID,
                               action: { play(track) })
                })
            }
            if !model.recentSearches.isEmpty {
                popoverGroup("Recent Searches", model.recentSearches.map { query in
                    PopoverRow(title: query, subtitle: "", trailing: "",
                               icon: "magnifyingglass",
                               action: { model.searchText = query })
                })
            }
        }
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous)
                .strokeBorder(Tokens.Palette.popoverBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
    }

    private func play(_ track: Track) {
        guard let album = model.album(for: track.albumKey) else { return }
        playback.play(track, in: album.discs.flatMap(\.tracks))
        model.endSearch()
        onPick()
    }
}

// MARK: - Shared popover row

/// One row in a titled group — an artist, album, track, recent play, or
/// recent search. Shared between `SearchResultsPopover` and
/// `SearchSuggestionsPopover` so the two look like one continuous surface.
private struct PopoverRow: Identifiable {
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
private func popoverGroup(_ label: String, _ rows: [PopoverRow]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        SectionLabel(label, size: 9.5)
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.top, Tokens.Space.m)
            .padding(.bottom, 6)
        ForEach(rows) { row in
            Button(action: row.action) {
                HStack(spacing: Tokens.Space.m) {
                    if let icon = row.icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(hex: 0x7A7A85))
                            .frame(width: 26, height: 26)
                    } else {
                        ArtworkView(artworkID: row.artworkID,
                                    cornerRadius: 3,
                                    isCircular: row.isRound,
                                    stripe: 4,
                                    displaySize: 32)
                            .frame(width: 26, height: 26)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(Tokens.Typography.sans(12.5, .semibold))
                            .foregroundStyle(Color(hex: 0xDCDCE3))
                            .lineLimit(1)
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(Tokens.Typography.sans(10.5, .medium))
                                .foregroundStyle(Color(hex: 0x6A6A74))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Tokens.Space.s)
                    Text(row.trailing)
                        .font(Tokens.Typography.mono(10))
                        .foregroundStyle(Tokens.Palette.textFaint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .hoverHighlight(radius: Tokens.Radius.control,
                                hoverColor: Color(hex: 0x1F1F26))
                .padding(.horizontal, 6)
            }
            .plainControl()
        }
    }
}

private struct TopHitRow: View {
    var album: Album
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.m) {
                ArtworkView(artworkID: album.artworkID, cornerRadius: Tokens.Radius.thumb,
                                displaySize: 48)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(Tokens.Typography.sans(13, .bold))
                        .foregroundStyle(Color(hex: 0xF1F1F5))
                        .lineLimit(1)
                    Text([("Album"), album.albumArtist, album.year.map(String.init)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Tokens.Typography.sans(11, .medium))
                        .foregroundStyle(Color(hex: 0x7C7C86))
                        .lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.s)
                Text("TOP HIT")
                    .font(Tokens.Typography.mono(9.5, .medium))
                    .tracking(0.8)
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(Color(hex: 0x1F1F26))
            }
            .padding(.horizontal, 6)
        }
        .plainControl()
    }
}
