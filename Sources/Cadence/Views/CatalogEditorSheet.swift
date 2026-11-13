import SwiftUI
import CadenceDesign
import CadenceCore

/// Makes a catalog, or changes one: a name, whether albums must pass all of
/// the rules or any, and the rules themselves. The count at the bottom follows
/// every edit, so you can see what the rules pick out before saving them.
///
/// Edits are staged in the sheet; Cancel is a true no-op.
struct CatalogEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var editing: AppModel.CatalogEditing

    @State private var name: String
    @State private var definition: Catalog.Definition
    @FocusState private var focus: Field?

    init(editing: AppModel.CatalogEditing) {
        self.editing = editing
        switch editing {
        case .create:
            // The suggested name needs the model, so it is filled on appear.
            _name = State(initialValue: "")
            _definition = State(initialValue: Catalog.Definition(rules: [CatalogRule(field: .label)]))
        case .edit(let catalog):
            var definition = catalog.definition
            if definition.rules.isEmpty { definition.rules = [CatalogRule(field: .label)] }
            _name = State(initialValue: catalog.name)
            _definition = State(initialValue: definition)
        }
    }

    /// Which text field has the keyboard: the name, or one rule's value.
    enum Field: Hashable {
        case name
        case rule(CatalogRule.ID)
    }

    private var isCreating: Bool {
        if case .create = editing { return true }
        return false
    }

    private var matches: [Album] { model.previewAlbums(for: definition) }
    private var canSave: Bool { !definition.completeRules.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(isCreating ? "New catalog" : "Edit catalog")
                    .font(Tokens.Typography.sans(16, .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text("Gather albums by label, year, format and more. New albums that fit join on their own.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }

            CatalogTextField(placeholder: "Catalog name", text: $name,
                             isFocused: focus == .name)
                .focused($focus, equals: .name)
                .onSubmit(save)

            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                HStack(spacing: Tokens.Space.s) {
                    Text("Include albums that match")
                    DropdownField(title: definition.match == .all ? "all" : "any",
                                  accessibilityLabel: "Match all or any rules",
                                  minWidth: 64) {
                        Catalog.Match.allCases.map { match in
                            .choice(match == .all ? "all" : "any", isOn: definition.match == match) {
                                definition.match = match
                            }
                        }
                    }
                    Text("of these rules")
                }
                .font(Tokens.Typography.sans(13, .medium))
                .foregroundStyle(Tokens.Palette.textSecondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Space.s) {
                        ForEach($definition.rules) { $rule in
                            RuleRow(rule: $rule, focus: $focus,
                                    canRemove: definition.rules.count > 1) {
                                definition.rules.removeAll { $0.id == rule.id }
                            }
                            // The focused row's drop-down has to draw over
                            // the rows after it.
                            .zIndex(focus == .rule(rule.id) ? 1 : 0)
                        }
                    }
                    .padding(.vertical, 2)
                }
                // Lets a drop-down hang past the bottom of the rule list.
                .scrollClipDisabled()
                .zIndex(1)
                // A fixed height, not one that hugs the rows: an open
                // drop-down hangs below its field, and a sheet only as tall
                // as its rows would clip it at the window's edge.
                .frame(height: 300, alignment: .top)

                CapsuleButton(title: "Add Rule", systemImage: "plus") {
                    let rule = CatalogRule(field: nextField)
                    definition.rules.append(rule)
                    if rule.field.isText { focus = .rule(rule.id) }
                }
            }
            // Above the footer, so an open drop-down draws over it.
            .zIndex(1)

            Rectangle().fill(Tokens.Palette.fieldBorder).frame(height: 1)

            HStack(spacing: Tokens.Space.m) {
                CoverMosaic(artworkIDs: Catalog.covers(of: matches),
                            cornerRadius: 4, displaySize: 80)
                    .frame(width: 36, height: 36)
                    .opacity(matches.isEmpty ? 0.4 : 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(matches.count == 1 ? "1 album matches" : "\(matches.count) albums match")
                        .font(Tokens.Typography.sans(13, .semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Text(canSave ? definition.summary : "Fill in a rule to see what it picks out.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: Tokens.Space.m)
                CapsuleButton(title: "Cancel") { dismiss() }
                CapsuleButton(title: isCreating ? "Create" : "Save", kind: .filled, action: save)
                    .disabled(!canSave)
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 720)
        .background(Tokens.Palette.popover)
        .onAppear {
            if case .create = editing, name.isEmpty {
                name = model.suggestedCatalogName
            }
            focus = .name
        }
        .onExitCommand { dismiss() }
    }

    /// A new rule starts on a field the catalog does not use yet, so "Add
    /// Rule" twice does not stack up two Label rows.
    private var nextField: CatalogRule.Field {
        let used = Set(definition.rules.map(\.field))
        return CatalogRule.Field.allCases.first { !used.contains($0) } ?? .label
    }

    private func save() {
        guard canSave else { return }
        let (name, definition, editing) = (name, definition, editing)
        dismiss()
        Task { await model.saveCatalog(name: name, definition: definition, editing: editing) }
    }
}

// MARK: - Rule row

/// One rule: field, comparison, value, and a remove button. A name field
/// offers the library's values in a drop-down while it is being typed in.
private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: CatalogRule
    var focus: FocusState<CatalogEditorSheet.Field?>.Binding
    var canRemove: Bool
    var remove: () -> Void

    private var isFocused: Bool { focus.wrappedValue == .rule(rule.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Tokens.Space.s) {
                DropdownField(title: rule.field.title, accessibilityLabel: "Rule field",
                              minWidth: 116) {
                    CatalogRule.Field.allCases.map { field in
                        .choice(field.title, isOn: rule.field == field) { rule.change(to: field) }
                    }
                }
                DropdownField(title: rule.op.title, accessibilityLabel: "Comparison",
                              minWidth: 132) {
                    rule.field.operators.map { op in
                        .choice(op.title, isOn: rule.op == op) { rule.op = op }
                    }
                }
                value
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton(systemImage: "minus.circle", label: "Remove rule",
                           glyphSize: 13, side: 28, action: remove)
                    .disabled(!canRemove)
                    .opacity(canRemove ? 1 : 0.3)
            }
            labelHint
        }
    }

    // MARK: Value

    @ViewBuilder
    private var value: some View {
        switch rule.field {
        case .label, .artist, .genre:
            // "Contains" takes a keyword, not a value from the library, so it
            // gets a plain field with no drop-down.
            SuggestionField(placeholder: placeholder, text: $rule.text,
                            values: isKeyword ? [] : model.catalogValues(for: rule.field),
                            isFocused: isFocused)
                .focused(focus, equals: .rule(rule.id))
        case .year:
            HStack(spacing: Tokens.Space.s) {
                yearField($rule.number, placeholder: "1975")
                if rule.op == .between {
                    Text("and")
                        .font(Tokens.Typography.sans(13, .medium))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                    yearField($rule.upperNumber, placeholder: "1985")
                }
            }
        case .decade:
            let decades = model.catalogValues(for: .decade).compactMap(Int.init)
            DropdownField(title: rule.number.map { "\($0)s" } ?? "Choose decade",
                          accessibilityLabel: "Decade", minWidth: 140) {
                decades.isEmpty
                    ? [.action("No dated albums", "info.circle", enabled: false) {}]
                    : decades.map { decade in
                        .choice("\(decade)s", isOn: rule.number == decade) { rule.number = decade }
                    }
            }
        case .format:
            DropdownField(title: rule.text.isEmpty ? "Choose format"
                                                   : CatalogRule.FormatChoice.title(for: rule.text),
                          accessibilityLabel: "Format", minWidth: 140) {
                let values = model.catalogValues(for: .format)
                var items: [MenuItem] = values.prefix(3).map(formatChoice)
                if values.count > 3 {
                    items.append(.separator)
                    items += values.dropFirst(3).map(formatChoice)
                }
                return items
            }
        case .dateAdded:
            DropdownField(title: CatalogRule.spanTitle(days: rule.number ?? 30),
                          accessibilityLabel: "Time span", minWidth: 120) {
                CatalogRule.dateAddedSpans.map { days in
                    .choice(CatalogRule.spanTitle(days: days), isOn: rule.number == days) {
                        rule.number = days
                    }
                }
            }
        }
    }

    private func formatChoice(_ value: String) -> MenuItem {
        .choice(CatalogRule.FormatChoice.title(for: value), isOn: rule.text == value) {
            rule.text = value
        }
    }

    private var isKeyword: Bool { [.contains, .doesNotContain].contains(rule.op) }

    private var placeholder: String {
        if isKeyword { return "Keyword" }
        return switch rule.field {
        case .label: "Label, e.g. ECM"
        case .artist: "Artist name"
        default: "Genre"
        }
    }

    /// Digits only, four at most, and read live so the count follows typing
    /// rather than waiting for Return.
    private func yearField(_ number: Binding<Int?>, placeholder: String) -> some View {
        CatalogTextField(
            placeholder: placeholder,
            text: Binding(
                get: { number.wrappedValue.map(String.init) ?? "" },
                set: { number.wrappedValue = Int(String($0.filter(\.isNumber).prefix(4))) }),
            isFocused: false)
            .frame(width: 84)
    }

    // MARK: Suggestions

    /// Only says something when there is nothing to suggest because no file
    /// carries a label yet — the one gap the user can do something about.
    @ViewBuilder
    private var labelHint: some View {
        if rule.field == .label && isFocused && model.catalogValues(for: .label).isEmpty {
            Text("No labels in your library yet. Labels are read from the files' LABEL, ORGANIZATION or PUBLISHER tag — use Rescan Library, Re-reading Every File to pick them up.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 116 + 132 + Tokens.Space.s * 2)
        }
    }
}

/// A text field with a drop-down of the library's values under it: every
/// value A–Z while the field is empty, narrowed as you type — names that
/// start with the text first, then names that contain it.
///
/// The list floats over the sheet rather than pushing the rows below it
/// down. ↑ and ↓ move through it, Return picks, Escape closes it. Those keys
/// are caught with a local event monitor while the field has focus, as the
/// search field does: the field editor answers the arrows before SwiftUI's
/// own key handling would ever see them.
private struct SuggestionField: View {
    var placeholder: String
    @Binding var text: String
    var values: [String]
    var isFocused: Bool

    @State private var highlight: Int?
    /// Set only by the arrow keys. Scrolling follows this rather than
    /// `highlight`, which hover also moves — scrolling to the row under the
    /// pointer made the list jump away from it.
    @State private var scrollTarget: Int?
    @State private var isDismissed = false
    /// The value last picked from the list. Picking sets the text, and the
    /// list should stay shut for that change rather than reopen on it.
    @State private var picked: String?
    @State private var keyMonitor: Any?

    private static let rowHeight: CGFloat = 28
    private static let visibleRows: CGFloat = 6.5

    private var matches: [String] { Self.matches(for: text, in: values) }
    private var isOpen: Bool { isFocused && !isDismissed && !matches.isEmpty }

    var body: some View {
        CatalogTextField(placeholder: placeholder, text: $text, isFocused: isFocused)
            .overlay(alignment: .topLeading) {
                if isOpen {
                    list
                        .offset(y: 34)
                        .transition(.opacity)
                }
            }
            .onChange(of: text) { _, new in
                highlight = nil
                scrollTarget = nil
                isDismissed = new == picked
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    installKeyMonitor()
                } else {
                    removeKeyMonitor()
                    highlight = nil
                    isDismissed = false
                }
            }
            .onAppear { if isFocused { installKeyMonitor() } }
            .onDisappear(perform: removeKeyMonitor)
    }

    private var list: some View {
        let matches = matches
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element) { index, value in
                        SuggestionRow(title: value, isHighlighted: index == highlight) {
                            pick(value)
                        }
                        .onHover { if $0 { highlight = index } }
                        .id(index)
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(matches.count), Self.visibleRows) * Self.rowHeight + 8)
            .onChange(of: scrollTarget) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.popover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.popoverBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    private func pick(_ value: String) {
        picked = value
        isDismissed = true
        text = value
    }

    /// At most 200, so a library with thousands of artists does not build a
    /// row for each of them on every keystroke.
    static func matches(for typed: String, in values: [String]) -> [String] {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return Array(values.prefix(200)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var prefix: [String] = []
        var inside: [String] = []
        for value in values where value.compare(typed, options: options) != .orderedSame {
            if value.range(of: typed, options: options.union(.anchored)) != nil {
                prefix.append(value)
            } else if value.range(of: typed, options: options) != nil {
                inside.append(value)
            }
        }
        return Array((prefix + inside).prefix(200))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Bindings, not `self`: the closure outlives this `body`, and a
        // captured copy of the view would read stale state.
        let (text, highlight, isDismissed, picked) = ($text, $highlight, $isDismissed, $picked)
        let scrollTarget = $scrollTarget
        let values = values
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let matches = Self.matches(for: text.wrappedValue, in: values)
            guard !isDismissed.wrappedValue, !matches.isEmpty else { return event }
            switch event.keyCode {
            case 125:  // Down
                highlight.wrappedValue = min((highlight.wrappedValue ?? -1) + 1, matches.count - 1)
                scrollTarget.wrappedValue = highlight.wrappedValue
                return nil
            case 126:  // Up
                highlight.wrappedValue = max((highlight.wrappedValue ?? 0) - 1, 0)
                scrollTarget.wrappedValue = highlight.wrappedValue
                return nil
            case 36, 76:  // Return, Enter
                guard let index = highlight.wrappedValue, matches.indices.contains(index) else {
                    return event
                }
                picked.wrappedValue = matches[index]
                isDismissed.wrappedValue = true
                text.wrappedValue = matches[index]
                return nil
            case 53:  // Escape closes the list, not the sheet
                isDismissed.wrappedValue = true
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct SuggestionRow: View {
    var title: String
    var isHighlighted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Typography.sans(13, .medium))
                .foregroundStyle(isHighlighted ? Tokens.Palette.textPrimary : Tokens.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHighlighted ? Tokens.Palette.popoverHover : .clear)
                }
                .contentShape(Rectangle())
        }
        .plainControl()
        .focusable(false)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}


// MARK: - Controls

/// The naming sheet's text field, at the height of the rule dropdowns.
private struct CatalogTextField: View {
    var placeholder: String
    @Binding var text: String
    var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Tokens.Typography.sans(13.5, .medium))
            .foregroundStyle(Tokens.Palette.textPrimary)
            .textEntryFocus(isFocused)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.fieldFocusBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(isFocused ? Tokens.Palette.fieldFocusBorder
                                            : Tokens.Palette.fieldBorder, lineWidth: 1)
            }
            .accessibilityLabel(placeholder)
    }
}

/// A field-shaped button that opens a Cadence menu of choices — the rule
/// editor's stand-in for a pop-up button.
private struct DropdownField: View {
    var title: String
    var accessibilityLabel: String
    var minWidth: CGFloat
    var items: () -> [MenuItem]

    @State private var isHovering = false

    var body: some View {
        MenuAnchor(items: items) { isOpen, toggle in
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    CadenceIcon("chevron.down", size: 10)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                .font(Tokens.Typography.sans(13, .semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .padding(.horizontal, 10)
                .frame(minWidth: minWidth, alignment: .leading)
                .frame(height: 30)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(isOpen || isHovering ? Tokens.Palette.navActive
                                                   : Tokens.Palette.fieldBackground)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .strokeBorder(isOpen ? Tokens.Palette.fieldFocusBorder
                                             : Tokens.Palette.fieldBorder, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .plainControl()
            .animatedHover($isHovering)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(title)
        }
    }
}
