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
                    Text("Where were you? Who were you with? Why does it matter?")
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
                    Text(memory.text)
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
