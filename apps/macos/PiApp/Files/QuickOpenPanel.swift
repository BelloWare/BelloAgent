import SwiftUI

/// ⌘P's list over the window: a field, the files found, and a line saying
/// what the list is (and what the keys do). A click outside closes it; the
/// keys it answers are taken before anything else in the window
/// (`WorkspaceModel.quickOpenKey`).
struct QuickOpenLayer: NSViewRepresentable {
    @ObservedObject var quickOpen: QuickOpen
    /// Opens a row's file, or the chosen one's without one.
    let open: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> QuickOpenAnchor { QuickOpenAnchor() }
    func updateNSView(_ view: QuickOpenAnchor, context: Context) { context.coordinator.show(quickOpen, open: open) }
    static func dismantleNSView(_ view: QuickOpenAnchor, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator {
        private weak var window: NSWindow?
        private var cover: NSView?
        func show(_ quickOpen: QuickOpen, open: @escaping (String?) -> Void) {
            guard let target = quickOpen.presentationWindow, let content = target.contentView else { close(); return }
            guard window !== target || cover?.superview !== content else { return }
            close()
            let hosted = NSHostingView(rootView: QuickOpenWindowLayer(quickOpen: quickOpen, open: open))
            hosted.frame = content.bounds
            hosted.autoresizingMask = [.width, .height]
            content.addSubview(hosted, positioned: .above, relativeTo: nil)
            window = target; cover = hosted
        }
        func close() { cover?.removeFromSuperview(); cover = nil; window = nil }
    }
}

/// The workspace's anchor never takes mouse events from the main window.
final class QuickOpenAnchor: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct QuickOpenWindowLayer: View {
    @ObservedObject var quickOpen: QuickOpen
    let open: (String?) -> Void
    var body: some View {
        if quickOpen.isOpen {
            GeometryReader { region in
                ZStack(alignment: .top) {
                    // Everywhere else: a click there closes the list.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { quickOpen.close(restoringFocus: true) }
                        .accessibilityHidden(true)
                    QuickOpenPanel(quickOpen: quickOpen, open: open)
                        .frame(width: min(QuickOpenPanel.width, max(320, region.size.width - 80)))
                        .padding(.top, QuickOpenPanel.top)
                }
            }
        }
    }
}

struct QuickOpenPanel: View {
    @ObservedObject var quickOpen: QuickOpen
    let open: (String?) -> Void
    @FocusState private var fieldFocused: Bool
    @State private var hovered: String?

    static let width: CGFloat = 640
    static let top: CGFloat = 56
    static let rowHeight: CGFloat = 32
    static let visibleRows = 12

    var body: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(Color.piHairline).frame(height: 1)
            if !quickOpen.rows.isEmpty { list }
            footer
        }
        .piElevated(radius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open File")
        .accessibilityIdentifier("quickOpen")
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.piInkTertiary)
            TextField(placeholder, text: $quickOpen.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Color.piInk)
                .focused($fieldFocused)
                .accessibilityLabel("Find a file")
                .accessibilityIdentifier("quickOpenField")
            if quickOpen.status == .listing { PiSpinner(size: 12) }
        }
        .padding(.horizontal, 14).frame(height: 46)
        .onAppear { fieldFocused = true }
    }

    private var placeholder: String {
        quickOpen.project.map { "Find a file in \($0.name)" } ?? "Find a file"
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if quickOpen.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Opened lately").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
                            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
                    }
                    ForEach(quickOpen.rows) { row in
                        QuickOpenRow(row: row, selected: row.id == quickOpen.selection, hovered: row.id == hovered)
                            .id(row.id)
                            .onHover { inside in hovered = inside ? row.id : (hovered == row.id ? nil : hovered) }
                            .onTapGesture { open(row.id) }
                            .accessibilityAction { open(row.id) }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: min(CGFloat(quickOpen.rows.count), CGFloat(Self.visibleRows)) * Self.rowHeight + 12
                   + (quickOpen.query.trimmingCharacters(in: .whitespaces).isEmpty ? 26 : 0))
            .onChange(of: quickOpen.selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(footerText).font(PiFont.caption).foregroundStyle(footerTone).lineLimit(2)
                if let warning = warningText {
                    Text(warning).font(PiFont.caption).foregroundStyle(Color.piWarning).lineLimit(2)
                        .help(quickOpen.warnings.joined(separator: "\n"))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.piSurfaceSunken)
        .overlay(alignment: .top) { Rectangle().fill(Color.piHairline).frame(height: 1).opacity(quickOpen.rows.isEmpty ? 0 : 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quickOpenStatus")
    }

    /// What the listing left out, when it did: the first thing, and how many more.
    private var warningText: String? {
        guard let first = quickOpen.warnings.first, quickOpen.status == .ready || quickOpen.status == .listing else { return nil }
        let more = quickOpen.warnings.count - 1
        return more > 0 ? first + " (and \(more) more)" : first
    }

    private var footerTone: Color {
        switch quickOpen.status {
        case .failed, .untrusted: return .piWarning
        default: return .piInkSecondary
        }
    }

    /// What the list is, or why it is empty, and what the keys do.
    var footerText: String {
        let name = quickOpen.project?.name ?? "the project"
        let coverage = quickOpen.truncated ? " Only the first \(quickOpen.searchedFileCount.formatted()) files are searched." : ""
        switch quickOpen.status {
        case .untrusted: return "\(name) is not trusted, so its files are not listed."
        case .failed(let reason):
            return (quickOpen.hasListing ? "List as last read. Refresh failed: \(reason)" : "The files in \(name) could not be listed: \(reason)") + coverage
        case .listing where quickOpen.rows.isEmpty: return "Finding the files in \(name)…" + coverage
        default: break
        }
        let typed = quickOpen.query.trimmingCharacters(in: .whitespaces)
        if quickOpen.rows.isEmpty {
            if typed.isEmpty { return "Type part of a file's name to find it in \(name). End with :N to open at line N." + coverage }
            return (quickOpen.searched ? "No file in \(name) matches “\(typed)”." : "Finding…") + coverage
        }
        var parts = ["↑↓ to choose", "↩ to open" + (quickOpen.line.map { " at line \($0)" } ?? ""), "esc to close"]
        if quickOpen.truncated { parts.append("only the first \(quickOpen.searchedFileCount.formatted()) files are searched") }
        return parts.joined(separator: " · ")
    }
}

/// One file of the list: its kind, its name and its folder, the query's
/// characters in accent ink.
struct QuickOpenRow: View {
    let row: QuickOpen.Row
    let selected: Bool
    let hovered: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: row.symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.piAccent : Color.piInkTertiary).frame(width: 16)
            Self.text(row.name, row.nameMatches, font: .system(size: 13, weight: .medium), ink: .piInk)
                .lineLimit(1).layoutPriority(1)
            if !row.folder.isEmpty {
                Self.text(row.folder, row.folderMatches, font: .system(size: 12), ink: .piInkSecondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: QuickOpenPanel.rowHeight)
        .background(RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous)
            .fill(selected ? Color.piAccentSoft : hovered ? Color.piFill : Color.clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// `string` with its UTF-8 ranges `matches` in accent ink, semibold.
    static func text(_ string: String, _ matches: [Range<Int>], font: Font, ink: Color) -> Text {
        let bytes = Array(string.utf8)
        var result = Text(verbatim: ""), at = 0
        for match in matches.sorted(by: { $0.lowerBound < $1.lowerBound }) where match.lowerBound >= at && match.upperBound <= bytes.count {
            if match.lowerBound > at {
                result = result + Text(verbatim: String(decoding: bytes[at..<match.lowerBound], as: UTF8.self)).foregroundColor(ink)
            }
            result = result + Text(verbatim: String(decoding: bytes[match], as: UTF8.self)).foregroundColor(.piAccent).fontWeight(.semibold)
            at = match.upperBound
        }
        if at < bytes.count { result = result + Text(verbatim: String(decoding: bytes[at...], as: UTF8.self)).foregroundColor(ink) }
        return result.font(font)
    }
}
