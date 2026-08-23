import SwiftUI

/// Answers one question, once: which modifier stops a `List` reorder from
/// engaging in this app?
///
/// `onMove` has never worked in Cadence — not in a playlist, not in Up Next
/// (issue #25) — and the cause cannot be found by reading, because synthetic
/// mouse events do not engage `onMove` at all. It needs a hand on a trackpad,
/// and a hand on a trackpad is expensive enough that guessing one modifier per
/// build is the wrong way to spend it.
///
/// So every suspect is on screen at once. Drag a row in each column and note
/// which columns reorder. The first column that fails names the modifier that
/// breaks it — or, if column 1 already fails, `onMove` does not engage in this
/// app at all and the reorder has to be built on `.draggable`, which demonstrably
/// does work here.
///
/// Deliberately free of `Tokens`, `AppModel` and every other app type: a
/// diagnostic that shares code with the thing it is diagnosing can fail for the
/// same reason and tell you nothing.
///
/// Delete once #25 is closed.
enum DragHarness {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--drag-check")
    }
}

struct DragCheckView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag a row in each column. Note which ones reorder.")
                .font(.system(size: 13, weight: .semibold))
            Text("The first column that fails names the cause. "
                 + "If column 1 fails, onMove does not engage in this app at all.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                Column(title: "1. bare") { BareList() }
                Column(title: "2. + plain style") { PlainStyleList() }
                Column(title: "3. + row modifiers") { RowModifierList() }
                Column(title: "4. + context menu") { ContextMenuList() }
                Column(title: "5. positional id") { PositionalIDList() }
            }
        }
        .padding(20)
        .frame(minWidth: 1000, minHeight: 460)
    }
}

private struct Column<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold))
            content
                .frame(width: 178, height: 340)
                .border(.secondary.opacity(0.4))
        }
    }
}

private let seed = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"]

/// Nothing but a List, a ForEach and onMove. If this one does not reorder,
/// no arrangement of modifiers is the problem.
private struct BareList: View {
    @State private var rows = seed

    var body: some View {
        List {
            ForEach(rows, id: \.self) { Text($0) }
                .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
        }
    }
}

private struct PlainStyleList: View {
    @State private var rows = seed

    var body: some View {
        List {
            ForEach(rows, id: \.self) { Text($0) }
                .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// The row dressing the real lists carry: cleared background, hidden
/// separator, zero insets and an explicit hit shape.
private struct RowModifierList: View {
    @State private var rows = seed

    var body: some View {
        List {
            ForEach(rows, id: \.self) { row in
                Text(row)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
            }
            .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// Column 3 plus everything else the real rows carry: the double-click, a
/// context menu, and the List's own selection with a tag. If columns 1-3 pass
/// and this one fails, the cause is in here. If all four pass, the harness does
/// not reproduce the bug and the cause is structural — something about the view
/// hierarchy `PlaylistDetailView` sits in, not the row itself.
private struct ContextMenuList: View {
    @State private var rows = seed
    @State private var selected: String?

    var body: some View {
        List(selection: $selected) {
            ForEach(rows, id: \.self) { row in
                Text(row)
                    .tag(row)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {}
                    .contextMenu { Button("Nothing") {} }
            }
            .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// The shape `PlaylistDetailView` actually has: a row whose identity *is* its
/// index, so no identity ever changes when the order does. Column 1 versus
/// this one is the whole test of whether that matters.
private struct PositionalIDList: View {
    private struct Row: Identifiable, Hashable {
        var position: Int
        var name: String
        var id: Int { position }
    }

    @State private var rows: [Row] = seed.enumerated().map {
        Row(position: $0.offset, name: $0.element)
    }

    var body: some View {
        List {
            ForEach(rows) { Text($0.name) }
                .onMove { source, destination in
                    rows.move(fromOffsets: source, toOffset: destination)
                    // Positions renumbered so identity stays positional, which
                    // is what the real list does on every reload.
                    rows = rows.enumerated().map {
                        Row(position: $0.offset, name: $0.element.name)
                    }
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
