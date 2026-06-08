import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex

/// Pure-SwiftUI sidebar (ScrollView + LazyVStack, not List/NSTableView) so it tracks
/// the emulated window's drag `.offset` smoothly without AppKit-layer flicker.
struct ProjectSidebar: View {
    @Environment(IndexCoordinator.self) private var index

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Listeler")
                    smartRow("Tüm oturumlar", "tray.full", .all)
                    smartRow("Bugün", "sun.max", .today)
                    smartRow("Sabitlenenler", "pin", .pinned)

                    sectionHeader("Projeler (\(index.projects.count))")
                    ForEach(index.projects) { project in
                        projectRow(project)
                    }
                }
                .padding(8)
            }
            Divider()
            Button {
                Task { await index.rescan() }
            } label: {
                Label("Yeniden tara", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(8)
            .disabled(index.isScanning)
        }
        .overlay {
            if index.isScanning {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Taranıyor…").font(.caption).foregroundStyle(.secondary)
                }
            } else if index.projects.isEmpty {
                ContentUnavailableView("Proje yok", systemImage: "folder", description: Text("Yeniden tara'ya bas"))
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isSelected(_ item: IndexCoordinator.SidebarItem) -> Bool {
        index.sidebarSelection == item
    }

    private func smartRow(_ title: String, _ icon: String, _ item: IndexCoordinator.SidebarItem) -> some View {
        rowShell(selected: isSelected(item)) { index.sidebarSelection = item } label: {
            Label(title, systemImage: icon).font(.callout)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        rowShell(selected: isSelected(.project(project.id))) {
            index.sidebarSelection = .project(project.id)
        } label: {
            ProjectRow(project: project)
        }
        .contextMenu {
            Button(project.pinned ? "Sabitlemeyi kaldır" : "Sabitle",
                   systemImage: project.pinned ? "pin.slash" : "pin") {
                index.toggleProjectPin(project.id)
            }
        }
    }

    /// A selectable row: tap to select, accent background when selected.
    @ViewBuilder
    private func rowShell<Label: View>(selected: Bool, action: @escaping () -> Void,
                                       @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.exists ? "folder" : "folder.badge.questionmark")
                .foregroundStyle(project.exists ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName).lineLimit(1)
                Text(project.decodedPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if project.pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
            }
            Text("\(project.sessionCount)").font(.caption).foregroundStyle(.secondary)
        }
        .help(project.decodedPath)
    }
}
