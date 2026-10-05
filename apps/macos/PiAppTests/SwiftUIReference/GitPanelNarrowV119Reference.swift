import AppKit
import SwiftUI
import GitView
@testable import PiApp

// Frozen narrow History layout from 0.1.119 (e59e41a7), GitPanel.swift.
// The toolbar, filters, rows, outer VStack and split use the original sizing.
// Actions are inert and the diff is a clear flexible child: this reference
// measures panel geometry, rather than duplicating Git reads or diff drawing.
// Background observers do not participate in layout.

@MainActor enum GitNarrowReferencePart: String, CaseIterable {
    case panel, header, toolbar, firstRow, branch, remote, stash, tabs
    case history, filter, author, list, firstCommit, detail
}

@MainActor final class GitNarrowReferenceGeometry {
    var frames: [GitNarrowReferencePart: CGRect] = [:]
    static let coordinateSpace = "git-narrow-v119-pane"
}

@MainActor private struct GitNarrowFrameObserver: View {
    let part: GitNarrowReferencePart
    let geometry: GitNarrowReferenceGeometry
    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(GitNarrowReferenceGeometry.coordinateSpace))
            Color.clear.onAppear { geometry.frames[part] = frame }
                .onChange(of: frame) { _, value in geometry.frames[part] = value }
        }
    }
}

@MainActor private extension View {
    func gitNarrowFrame(_ part: GitNarrowReferencePart, _ geometry: GitNarrowReferenceGeometry) -> some View {
        background(GitNarrowFrameObserver(part: part, geometry: geometry))
    }
}

@MainActor struct GitPanelNarrowV119Reference: View {
    @ObservedObject var controller: GitController
    let geometry: GitNarrowReferenceGeometry

    var body: some View {
        VStack(spacing: 0) {
            header.gitNarrowFrame(.header, geometry)
            toolbar.gitNarrowFrame(.toolbar, geometry)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            GitPanelNarrowSplitV119Reference {
                history.gitNarrowFrame(.history, geometry)
                Rectangle().fill(Color.piHairline)
                Color.clear.gitNarrowFrame(.detail, geometry)
            }
        }
        .background(Color.piContent)
        .gitNarrowFrame(.panel, geometry)
    }

    private var header: some View {
        HStack(spacing: PiSpacing.sm) {
            HStack(spacing: 4) {
                Text("\(controller.status.branch) · \(controller.status.entries.count) changed")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: PiSpacing.sm)
            PiIconButton(symbol: "arrow.clockwise", label: "Refresh changes", size: 26) {}
        }
        .padding(.horizontal, PiSpacing.md).frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.sm) {
                Label(controller.displayRoot, systemImage: "folder").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .lineLimit(1).truncationMode(.middle)
                PiMenuButton(title: controller.status.branch.isEmpty ? "detached" : controller.status.branch,
                             icon: "arrow.triangle.branch", maxLabelWidth: 150) {
                    PiMenuEntry.button("Fixture") {}
                }.gitNarrowFrame(.branch, geometry)
                remoteControls.gitNarrowFrame(.remote, geometry)
                PiMenuButton(title: "Stash", icon: "tray.and.arrow.down") {
                    PiMenuEntry.button("Fixture") {}
                }.gitNarrowFrame(.stash, geometry)
                Spacer(minLength: 0)
            }.gitNarrowFrame(.firstRow, geometry)
            HStack(spacing: PiSpacing.sm) {
                PiTabs(selection: .constant(GitController.Panel.history),
                       items: GitController.Panel.allCases.map { ($0, $0.title) })
                    .gitNarrowFrame(.tabs, geometry)
                Spacer()
            }
        }.padding(.horizontal, PiSpacing.lg).padding(.vertical, PiSpacing.sm)
    }

    private var remoteControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Button {} label: { Label("Fetch", systemImage: "arrow.down.to.line") }
                    .buttonStyle(.piSecondaryCompact).fixedSize()
                Button {} label: { Label("Pull", systemImage: "arrow.down.circle") }
                    .buttonStyle(.piSecondaryCompact).fixedSize()
                Button {} label: { Label("Push", systemImage: "arrow.up.circle") }
                    .buttonStyle(.piSecondaryCompact).fixedSize()
            }
            Color.clear.frame(width: 3 * 26 + 2 * 2, height: 26).overlay {
                HStack(spacing: 2) {
                    PiIconButton(symbol: "arrow.down.to.line", label: "Fetch", size: 26) {}
                    PiIconButton(symbol: "arrow.down.circle", label: "Pull", size: 26) {}
                    PiIconButton(symbol: "arrow.up.circle", label: "Push", size: 26) {}
                }
            }
        }
    }

    private var history: some View {
        VStack(spacing: 0) {
            VStack(spacing: PiSpacing.xs) {
                PiTextField(placeholder: "Filter by message or hash", text: .constant(""), icon: "magnifyingglass")
                    .gitNarrowFrame(.filter, geometry)
                HStack(spacing: PiSpacing.sm) {
                    PiTextField(placeholder: "Author", text: .constant(""), icon: "person")
                        .gitNarrowFrame(.author, geometry)
                    Button {} label: {
                        Image(systemName: "square").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.piInkTertiary).frame(width: 18, height: 18)
                    }.buttonStyle(.plain)
                    Text("All branches").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize()
                }
            }.padding(PiSpacing.sm)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.commits) { commit in
                        commitRow(commit).background {
                            if commit.hash == controller.commits.first?.hash {
                                GitNarrowFrameObserver(part: .firstCommit, geometry: geometry)
                            }
                        }
                    }
                }.padding(PiSpacing.sm)
            }.gitNarrowFrame(.list, geometry)
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        PiSelectableRow(selected: controller.selectedCommit == commit, action: {}) {
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject).font(PiFont.body).foregroundStyle(Color.piInk).lineLimit(2)
                if !commit.refs.isEmpty {
                    PiFlow(spacing: 4, rowSpacing: 4) {
                        ForEach(commit.refs, id: \.self) { ref in
                            PiBadge(text: ref.replacingOccurrences(of: "HEAD -> ", with: ""),
                                    tone: ref.hasPrefix("HEAD") ? .accent : ref.hasPrefix("tag: ") ? .warning : .info,
                                    icon: ref.hasPrefix("tag: ") ? "tag" : ref.hasPrefix("HEAD") ? "location" : nil)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text(commit.shortHash).font(PiFont.mono).foregroundStyle(Color.piAccent)
                    Text(commit.author).lineLimit(1)
                    Text(commit.date.formatted(.relative(presentation: .named))).lineLimit(1)
                    if commit.parents.count > 1 { Image(systemName: "arrow.triangle.merge") }
                }.font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            }
        }
    }
}

// The released narrow half of GitPanelSplit, including its original least
// height proposal. No native split helper is used by the reference.
@MainActor private struct GitPanelNarrowSplitV119Reference: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let (list, rule, detail) = (subviews[0], subviews[1], subviews[2])
        let fixed = list.sizeThatFits(ProposedViewSize(width: bounds.width, height: 0)).height
        let available = max(0, bounds.height - 1), least = fixed + 3 * 44
        let height = min(max((available * 0.45).rounded(), least), max(available - 180, least), available)
        list.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: height))
        rule.place(at: CGPoint(x: bounds.minX, y: bounds.minY + height), proposal: ProposedViewSize(width: bounds.width, height: 1))
        detail.place(at: CGPoint(x: bounds.minX, y: bounds.minY + height + 1),
                     proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - height - 1)))
    }
}
