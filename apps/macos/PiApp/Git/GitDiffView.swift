import SwiftUI
import AppKit

// Drawing a diff: the file chips of a commit, and the unified or
// side-by-side cards the hunks become.

/// The commit's files as chips; one narrows the diff to that file, "All"
/// widens it again. A flow layout measures every chip it is given, twice, on
/// the main thread, so a commit that touches thousands of files shows the
/// first few hundred and says how many more it has.
struct GitCommitFileChips: View {
    let detail: GitCommitDetail
    @Binding var selected: String?
    @Binding var shown: Int
    var showHistory: (String) -> Void
    static let step = 200

    var body: some View {
        let files = detail.files.count <= shown ? detail.files[...] : detail.files[..<shown]
        PiFlow {
            PiChip(text: "All \(detail.files.count) files", icon: selected == nil ? "checkmark" : nil) { selected = nil }
            ForEach(files) { file in chip(file) }
            if detail.files.count > shown {
                PiChip(text: "\(detail.files.count - shown) more files", icon: "ellipsis") { shown += Self.step }
                    .accessibilityIdentifier("git-commit-more-files")
            }
        }
    }

    private func chip(_ file: GitStatusEntry) -> some View {
        let stat = detail.stats[file.path]
        let counts = stat.map { $0.binary ? " · binary" : " · +\($0.added) −\($0.removed)" } ?? ""
        return Button { selected = selected == file.path ? nil : file.path } label: {
            PiBadge(text: "\(file.badge) \((file.path as NSString).lastPathComponent)" + counts,
                    tone: selected == file.path ? .accent : file.badge == "D" ? .danger : file.badge == "A" ? .success : .neutral)
        }.buttonStyle(.plain).piPointer().help(file.path + counts)
        .accessibilityIdentifier("git-commit-file-" + file.path)
        .contextMenu {
            Button("Show History of This File", systemImage: "clock.arrow.circlepath") { showHistory(file.path) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
        }
    }
}

/// Unified or side-by-side diff rendered as file cards with hunk headers,
/// old/new line numbers and tinted added/removed rows.
struct DiffView: View {
    let files: [GitDiffFile]
    let title: String?
    let subtitle: String?
    /// Names the diff on screen: the file selected, or the commit and the file
    /// chosen inside it. The "whole diff" gate is remembered against it.
    let identity: String
    var loading = false
    var embedded = false
    @Binding var split: Bool
    /// The diff the reader asked to see in full, by identity. Held by the
    /// controller, so choosing another file or commit closes the gate again.
    @Binding var expanded: String?
    @State private var wrap = false
    private static let rowLimit = 1_500
    private var showAll: Bool { expanded == identity }

    var body: some View {
        Group {
            if embedded { content } else { ScrollView { content } }
        }
        .background(Color.piContent)
    }

    /// Counted from what the parser already totalled, not by walking the lines again.
    private var totalRows: Int { files.reduce(0) { $0 + $1.lineCount } }

    private var content: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(PiFont.heading).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    if let subtitle { Text(subtitle).font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                PiTabs(selection: $split, items: [(false, "Unified"), (true, "Split")]).accessibilityIdentifier("git-diff-layout")
                Toggle("Wrap", isOn: $wrap).toggleStyle(.switch).controlSize(.mini).font(PiFont.micro)
            }.padding(.horizontal, PiSpacing.lg).padding(.top, embedded ? 0 : PiSpacing.lg)
            if files.isEmpty && !loading {
                Text("No textual changes.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(.horizontal, PiSpacing.lg)
            }
            ForEach(files) { file in fileCard(file) }
            if totalRows > Self.rowLimit && !showAll {
                Button("Show the whole diff") { expanded = identity }.buttonStyle(.piSecondaryCompact).padding(.horizontal, PiSpacing.lg)
                    .accessibilityIdentifier("git-diff-show-all")
            }
        }.padding(.bottom, PiSpacing.lg)
    }

    private func fileCard(_ file: GitDiffFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PiSpacing.sm) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Color.piInkSecondary)
                Text(file.renamed ? "\(file.oldPath) → \(file.newPath)" : file.path).font(PiFont.mono).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if file.added > 0 { Text("+\(file.added)").font(PiFont.micro.monospacedDigit()).foregroundStyle(Color.piSuccess) }
                if file.removed > 0 { Text("−\(file.removed)").font(PiFont.micro.monospacedDigit()).foregroundStyle(Color.piDanger) }
            }.padding(.horizontal, PiSpacing.md).padding(.vertical, 7).background(Color.piSurfaceSunken)
            ForEach(file.notes, id: \.self) { note in
                Text(note).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).padding(.horizontal, PiSpacing.md).padding(.vertical, 4)
            }
            // Only the rows the budget allows are ever built: a ForEach that
            // walks every line of a 20,000-line patch to throw it away costs
            // the same whether or not anything is drawn.
            LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(visibleHunks(of: file)) { piece in
                Text(piece.hunk.header).font(PiFont.mono).foregroundStyle(Color.piInfo).lineLimit(1)
                    .padding(.horizontal, PiSpacing.md).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).background(Color.piInfo.opacity(0.06))
                if split {
                    ForEach(piece.hunk.splitRows(limit: piece.budget)) { row in splitRow(row) }
                } else {
                    ForEach(piece.hunk.lines.prefix(piece.budget), id: \.id) { line in diffRow(line) }
                }
            }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .padding(.horizontal, PiSpacing.lg)
    }

    /// One hunk and how many of its rows are still inside the budget.
    private struct HunkSlice: Identifiable { let hunk: GitDiffHunk; let budget: Int; var id: Int { hunk.id } }
    private func visibleHunks(of file: GitDiffFile) -> [HunkSlice] {
        var remaining = showAll ? Int.max : Self.rowLimit, slices: [HunkSlice] = []
        for hunk in file.hunks {
            guard remaining > 0 else { break }
            slices.append(HunkSlice(hunk: hunk, budget: remaining))
            remaining = hunk.lines.count >= remaining ? 0 : remaining - hunk.lines.count
        }
        return slices
    }

    private func tint(_ kind: GitDiffLine.Kind) -> Color {
        switch kind { case .added: .piSuccess; case .removed: .piDanger; case .context, .note: .clear }
    }

    private func diffRow(_ line: GitDiffLine) -> some View {
        let tint = tint(line.kind)
        let marker = switch line.kind { case .added: "+"; case .removed: "−"; case .context: " "; case .note: "\\" }
        return HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing).padding(.trailing, 8)
            Text(marker).frame(width: 12, alignment: .center).foregroundStyle(line.kind == .context ? Color.piInkTertiary : tint)
            Text(line.text.isEmpty ? " " : line.text).lineLimit(wrap ? nil : 1).truncationMode(.tail).textSelection(.enabled)
                .foregroundStyle(line.kind == .note ? Color.piInkTertiary : Color.piInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(PiFont.mono)
        .foregroundStyle(Color.piInkTertiary)
        .padding(.vertical, 1).padding(.horizontal, PiSpacing.sm)
        .background(line.kind == .context || line.kind == .note ? Color.clear : tint.opacity(0.10))
    }

    /// Old text on the left, new text on the right; a blank half is a line that exists only on the other side.
    private func splitRow(_ row: GitSplitRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            splitHalf(row.left, number: row.left?.oldNumber, blank: row.left == nil)
            Rectangle().fill(Color.piHairline).frame(width: 1)
            splitHalf(row.right, number: row.right?.newNumber, blank: row.right == nil)
        }
        .font(PiFont.mono)
        .padding(.vertical, 1)
    }

    private func splitHalf(_ line: GitDiffLine?, number: Int?, blank: Bool) -> some View {
        let kind = line?.kind ?? .context
        let tint = tint(kind)
        return HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "").frame(width: 40, alignment: .trailing).padding(.trailing, 8).foregroundStyle(Color.piInkTertiary)
            Text(line.map { $0.text.isEmpty ? " " : $0.text } ?? " ").lineLimit(wrap ? nil : 1).truncationMode(.tail).textSelection(.enabled)
                .foregroundStyle(kind == .note ? Color.piInkTertiary : Color.piInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PiSpacing.sm)
        .background(blank ? Color.piFill.opacity(0.5) : kind == .context || kind == .note ? Color.clear : tint.opacity(0.10))
    }
}
