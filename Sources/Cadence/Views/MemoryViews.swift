import SwiftUI
import CadenceCore

// MARK: - Editor

/// Writing or changing a memory: a few lines of text against a song or a
/// record. One field and Save, like naming a playlist — a note is meant to be
/// jotted, not composed.
struct MemoryEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var editing: AppModel.MemoryEditing

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var isEditing: Bool {
        if case .edit = editing { return true }
        return false
    }

    private var remaining: Int { Memory.maximumLength - text.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(isEditing ? "Edit memory" : "New memory")
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(subjectLine)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(2)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    // `TextEditor` has no placeholder of its own.
                    Text("Where were you? Who were you with? Add #tags like #Axel to group notes.")
                        .font(Tokens.Typography.sans(13.5, .medium))
                        .foregroundStyle(Tokens.Palette.textFaint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .font(Tokens.Typography.sans(13.5, .medium))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .textEntryFocus(isFocused)
                    .accessibilityLabel("Memory")
                    .onChange(of: text) { _, new in
                        // "Small" is enforced as you type rather than at save,
                        // so nothing you wrote is silently cut off.
                        if new.count > Memory.maximumLength {
                            text = String(new.prefix(Memory.maximumLength))
                        }
                    }
            }
            .padding(Tokens.Space.s)
            .frame(height: 140)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.fieldFocusBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(isFocused ? Tokens.Palette.fieldFocusBorder
                                            : Tokens.Palette.fieldBorder, lineWidth: 1)
            }

            HStack(spacing: Tokens.Space.s) {
                if case .edit(let memory) = editing {
                    CapsuleButton(title: "Delete") {
                        dismiss()
                        Task { await model.deleteMemory(memory) }
                    }
                }
                Text(remaining <= 80 ? "\(remaining) left" : "")
                    .font(Tokens.Typography.monoSmall)
                    .foregroundStyle(Tokens.Palette.textFaint)
                    .accessibilityHidden(remaining > 80)
                Spacer(minLength: 0)
                CapsuleButton(title: "Cancel") { dismiss() }
                CapsuleButton(title: "Save", kind: .filled, action: commit)
                    .disabled(Memory.cleaned(text) == nil && !isEditing)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 440)
        .background(Tokens.Palette.popover)
        .onAppear {
            if case .edit(let memory) = editing { text = memory.text }
            isFocused = true
        }
        .onExitCommand { dismiss() }
    }

    /// What the note is about, in full: the song and the record it is on.
    private var subjectLine: String {
        switch editing.subject {
        case .album(let key):
            return "\(key.title) · \(key.albumArtist)"
        case .track(let title, let artist, let album):
            return "“\(title)” · \(artist) · from \(album.title)"
        }
    }

    private func commit() {
        let text = text
        let editing = editing
        dismiss()
        Task { await model.saveMemory(text: text, editing: editing) }
    }
}

// MARK: - A note on screen

/// One memory as a card: the note in its own words, then what it is about and
/// when it was written. Clicking does whatever the place it sits in wants —
/// open the record from Home, edit the note on the album page.
struct MemoryCard: View {
    var memory: Memory
    /// Heading over the note — the song for a track note. Nil leaves the
    /// card to the text alone, for a record's notes on its own page.
    var heading: String?
    /// The second line under the note, e.g. the artist and record.
    var detail: String?
    var artworkID: Artwork.ID?
    var showsArtwork = false
    var actionLabel: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                if showsArtwork {
                    ArtworkView(artworkID: artworkID, cornerRadius: Tokens.Radius.thumb,
                                stripe: 4, displaySize: 96)
                        .frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    if let heading {
                        HStack(spacing: 6) {
                            CadenceIcon("text.bubble", size: 10)
                                .foregroundStyle(Tokens.Palette.accent)
                            Text(heading)
                                .font(Tokens.Typography.sans(12, .bold))
                                .foregroundStyle(Tokens.Palette.textPrimary)
                                .lineLimit(1)
                        }
                    }
                    Text(MemoryText.styled(memory.text))
                        .font(Tokens.Typography.sans(13, .medium))
                        .foregroundStyle(Color(hex: 0xD6D6DD))
                        .lineSpacing(2)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([detail, memory.dateDescription].compactMap { $0 }
                        .joined(separator: " · "))
                        .font(Tokens.Typography.captionSmall)
                        .foregroundStyle(Tokens.Palette.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Tokens.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isHovering ? Tokens.Palette.rowHover : Tokens.Palette.card,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(actionLabel)
    }

    private var spokenLabel: String {
        ["Memory", heading, memory.text, detail, memory.dateDescription]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - On the album page

/// The record's memories, under its tracklist: notes on the whole record and
/// on songs from it, newest first. Each opens the editor.
struct AlbumMemoriesSection: View {
    @Environment(AppModel.self) private var model
    var album: Album

    var body: some View {
        let notes = model.memories(aboutAlbum: album.key)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                HStack(spacing: 14) {
                    SectionLabel(notes.count == 1 ? "Memory" : "Memories", size: 10,
                                 color: Tokens.Palette.textMuted)
                    Rectangle().fill(Tokens.Palette.separator).frame(height: 1)
                    CapsuleButton(systemImage: "plus",
                                  accessibilityLabel: "Add a memory about \(album.title)") {
                        model.editingMemory = .create(.album(album.key))
                    }
                    .scaleEffect(0.75)
                    .frame(width: 30, height: 30)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Tokens.Space.m,
                                             alignment: .top)],
                          alignment: .leading, spacing: Tokens.Space.m) {
                    ForEach(notes) { memory in
                        MemoryCard(memory: memory,
                                   heading: memory.subject.trackTitle.map { "“\($0)”" },
                                   actionLabel: "Edits this memory") {
                            model.editingMemory = .edit(memory)
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.albumInset)
            .padding(.bottom, 44)
        }
    }
}

// MARK: - The Memories page

/// The Memories tab: a filter bar — a field and the `#tag` chips — over the
/// grid of every memory that passes it.
struct MemoriesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            MemoryFilterBar()
            if model.filteredMemories.isEmpty {
                noMatches
            } else {
                MemoryGrid()
            }
        }
    }

    private var noMatches: some View {
        EmptyState(
            systemImage: "magnifyingglass",
            title: "No memories match",
            message: "Nothing in your notes, or the songs and records they are about,\n"
                + "matches that. Try fewer words, or another tag."
        ) {
            CapsuleButton(title: "Clear Filter") { model.clearMemoryFilter() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The field that narrows the page as you type, and a chip per `#tag` —
/// picking one shows that group, and picking it again shows them all.
private struct MemoryFilterBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(spacing: Tokens.Space.s) {
                CadenceIcon("magnifyingglass", size: 11)
                    .foregroundStyle(Tokens.Palette.textMuted)
                TextField("Filter memories, songs, records or #tags", text: $model.memoryQuery)
                    .textFieldStyle(.plain)
                    .font(Tokens.Typography.sans(13, .medium))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .focused($isFocused)
                    .textEntryFocus(isFocused)
                    .onExitCommand { model.memoryQuery = "" }
                    .accessibilityLabel("Filter memories")
                if !model.memoryQuery.isEmpty {
                    IconButton(systemImage: "xmark.circle.fill", label: "Clear filter",
                               glyphSize: 10, side: 18) {
                        model.memoryQuery = ""
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: 420, minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.fieldBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(isFocused ? Tokens.Palette.fieldFocusBorder
                                            : Tokens.Palette.fieldBorder, lineWidth: 1)
            }

            if !model.memoryTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tokens.Space.s) {
                        TagChip(title: "All", count: model.memories.count,
                                isSelected: model.activeMemoryTag == nil) {
                            model.memoryTagFilter = nil
                        }
                        ForEach(model.memoryTags) { tag in
                            TagChip(title: "#\(tag.name)", count: tag.count,
                                    isSelected: model.activeMemoryTag?.key == tag.key) {
                                // Picking the chip that is already on goes
                                // back to all of them.
                                model.memoryTagFilter =
                                    model.memoryTagFilter == tag.key ? nil : tag.key
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Space.contentInset)
        .padding(.top, Tokens.Space.l)
        .padding(.bottom, Tokens.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One `#tag` in the filter bar: its name and how many notes carry it.
private struct TagChip: View {
    var title: String
    var count: Int
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Tokens.Typography.sans(12, .semibold))
                Text("\(count)")
                    .font(Tokens.Typography.mono(10.5))
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : Tokens.Palette.textFaint)
            }
            .foregroundStyle(isSelected ? .white : (isHovering ? Tokens.Palette.textPrimary
                                                               : Tokens.Palette.textSecondary))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                Capsule().fill(isSelected ? Tokens.Palette.accent
                               : (isHovering ? Tokens.Palette.navHover : Tokens.Palette.card))
            }
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(Tokens.Palette.border, lineWidth: 1)
                }
            }
        }
        .plainControl()
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title), \(count == 1 ? "1 memory" : "\(count) memories")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The filtered memories, newest first, as a grid sized like the Playlists
/// one: each card the record's cover, what the note is about, and the note.
struct MemoryGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        CardGrid(items: model.filteredMemories,
                 columnWidth: model.albumColumnWidth,
                 scrollAnchor: $model.memoryGridScrollAnchor,
                 // Off: typing belongs to the filter field above the grid.
                 typeAheadKey: nil,
                 open: { model.show(.album($0.subject.albumKey)) },
                 header: { EmptyView() }) { memory, _, isFocused, onSelect in
            MemoryGridCard(memory: memory, isKeyboardFocused: isFocused, onSelect: onSelect)
        }
    }
}

/// A note's text with its `#tags` picked out in the accent, so the words that
/// group it read as such wherever it is shown.
enum MemoryText {
    static func styled(_ text: String) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for range in Memory.tagRanges(in: text) {
            result += AttributedString(String(text[cursor..<range.lowerBound]))
            var tag = AttributedString(String(text[range]))
            tag.swiftUI.foregroundColor = Tokens.Palette.accent
            result += tag
            cursor = range.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }
}

/// Nothing written yet: what a memory is, and where they are added.
struct MemoriesEmptyState: View {
    var body: some View {
        EmptyState(
            systemImage: PlaylistMenu.Symbol.memory,
            title: "No memories yet",
            message: "Right-click a song or an album and choose Add Memory…\n"
                + "to keep a note about it — where you were, who it reminds you of."
        ) {
            EmptyView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.surface)
    }
}

/// One memory in the grid. The top half is a playlist card — square cover,
/// hover Play in the corner, title and a detail line — so the page reads as
/// part of the library; the note sits under it, as on the album page.
///
/// A tap gesture rather than a `Button`, for the reason `PlaylistCard` gives:
/// the hover Play button is a button of its own.
private struct MemoryGridCard: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var playback
    var memory: Memory
    var isKeyboardFocused: Bool = false
    var onSelect: () -> Void = {}

    @State private var isHovering = false
    @State private var isHoveringArt = false
    @State private var isHoveringPlay = false

    private var key: Album.Key { memory.subject.albumKey }
    /// Nil when the record has left the library: the note stays, its cover
    /// falls back to the placeholder, and there is nothing to open or play.
    private var album: Album? { model.album(for: key) }

    /// `Artist · Record` for a song's note, the artist alone for a record's.
    private var detail: String {
        memory.subject.trackTitle == nil ? key.albumArtist : "\(key.albumArtist) · \(key.title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title(of: memory.subject))
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Color(hex: 0xEBEBF0))
                    .lineLimit(1)
                Text(detail)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
            }
            note
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(isHovering && !isHoveringPlay ? 0.86 : 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .onTapGesture(perform: open)
        .cadenceContextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: Text("Play"), play)
        .accessibilityAction(named: Text("Edit memory"), edit)
    }

    private var artwork: some View {
        ArtworkView(artworkID: album?.artworkID, cornerRadius: Tokens.Radius.control,
                    caption: album == nil ? "NOT IN LIBRARY" : nil, displaySize: 320)
            .aspectRatio(1, contentMode: .fit)
            // Only while hovered, as on `PlaylistCard`.
            .overlay {
                if isHoveringArt && model.canPlay(memory) {
                    CoverPlayButton(subject: model.title(of: memory.subject),
                                    isHovered: $isHoveringPlay, action: play)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHoveringArt)
            .onHover { hovering in
                isHoveringArt = hovering
                if !hovering { isHoveringPlay = false }
            }
            .keyboardFocusRing(isKeyboardFocused,
                              in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                   style: .continuous))
    }

    /// The note, the album page's card in miniature: bubble, words, date.
    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CadenceIcon(PlaylistMenu.Symbol.memory, size: 10)
                    .foregroundStyle(Tokens.Palette.accent)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(MemoryText.styled(memory.text))
                    .font(Tokens.Typography.sans(12.5, .medium))
                    .foregroundStyle(Color(hex: 0xD6D6DD))
                    .lineSpacing(2)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(memory.dateDescription)
                .font(Tokens.Typography.captionSmall)
                .foregroundStyle(Tokens.Palette.textFaint)
                .padding(.leading, 20)
        }
        .padding(.top, 2)
    }

    private var menu: [MenuItem] {
        [
            .action("Play", PlaylistMenu.Symbol.play, enabled: model.canPlay(memory), play),
            .action("Open Album", "circle.circle", enabled: album != nil, open),
            .separator,
            .action("Edit Memory…", PlaylistMenu.Symbol.rename, edit),
            .action("Delete Memory", PlaylistMenu.Symbol.delete, destructive: true) {
                Task { await model.deleteMemory(memory) }
            },
        ]
    }

    private func open() {
        onSelect()
        guard album != nil else { return }
        model.show(.album(key))
    }

    private func play() { model.play(memory, on: playback) }
    private func edit() { model.editingMemory = .edit(memory) }

    private var spokenLabel: String {
        "Memory: \(model.title(of: memory.subject)), \(detail). \(memory.text). \(memory.dateDescription)"
    }
}

// MARK: - In the Now Playing pane

/// The playing song's newest memory, under the controls in the Now Playing
/// pane. Song notes only: a note on the whole record would sit there for
/// every track of it, and stop being about this one.
///
/// Collapsed to a few lines so a long note cannot crowd out the queue below;
/// "Show more" opens the rest when there is more. Clicking the note edits it.
struct NowPlayingMemory: View {
    @Environment(AppModel.self) private var model
    var track: Track

    /// Lines shown before "Show more".
    static let collapsedLines = 3

    @State private var isHovering = false
    @State private var isExpanded = false
    /// The note's height at full length and at the collapsed limit, measured
    /// off-screen, so "Show more" appears only when something is cut off.
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > collapsedHeight + 1 }

    var body: some View {
        let notes = model.memories(about: track)
        if let memory = notes.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CadenceIcon(PlaylistMenu.Symbol.memory, size: 10)
                        .foregroundStyle(Tokens.Palette.accent)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    noteText(memory.text)
                        .lineLimit(isExpanded ? nil : Self.collapsedLines)
                        .background(measured(memory.text, lines: nil, into: $fullHeight))
                        .background(measured(memory.text, lines: Self.collapsedLines,
                                             into: $collapsedHeight))
                        .contentShape(Rectangle())
                        .pointingHandCursor()
                        .onTapGesture { model.editingMemory = .edit(memory) }
                        .accessibilityLabel("Memory about \(track.title): \(memory.text)")
                        .accessibilityHint("Edits this memory")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(.default) { model.editingMemory = .edit(memory) }
                }
                HStack(spacing: Tokens.Space.s) {
                    Text(notes.count > 1
                         ? "\(memory.dateDescription) · +\(notes.count - 1) more"
                         : memory.dateDescription)
                        .font(Tokens.Typography.captionSmall)
                        .foregroundStyle(Tokens.Palette.textFaint)
                    Spacer(minLength: 0)
                    if isTruncated || isExpanded {
                        Button(isExpanded ? "Show less" : "Show more") {
                            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                        }
                        .plainControl()
                        .font(Tokens.Typography.sans(11, .bold))
                        .foregroundStyle(Tokens.Palette.accent)
                    }
                }
                .padding(.leading, 20)
            }
            .padding(Tokens.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Tokens.Palette.rowHover : Tokens.Palette.card,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.border, lineWidth: 1))
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .contain)
            // A new song starts folded, whatever the last one was left at.
            .onChange(of: track.id) { _, _ in isExpanded = false }
        }
    }

    private func noteText(_ text: String) -> some View {
        Text(MemoryText.styled(text))
            .font(Tokens.Typography.sans(12.5, .medium))
            .italic()
            .foregroundStyle(Color(hex: 0xD6D6DD))
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// An invisible copy of the note at `lines`, reporting its height. Laid
    /// out at the same width as the real one, so the two heights compare.
    private func measured(_ text: String, lines: Int?,
                          into height: Binding<CGFloat>) -> some View {
        noteText(text)
            .lineLimit(lines)
            .hidden()
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { height.wrappedValue = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, new in height.wrappedValue = new }
                }
            }
            .accessibilityHidden(true)
    }
}
