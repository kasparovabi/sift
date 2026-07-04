import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex

/// Pure-SwiftUI sidebar (ScrollView + LazyVStack, not List/NSTableView) so it tracks
/// the emulated window's drag `.offset` smoothly without AppKit-layer flicker.
struct ProjectSidebar: View {
    @Environment(IndexCoordinator.self) private var index
    @State private var hoveredProject: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Listeler")
                    smartRow("Tüm oturumlar", "tray.full", .all, count: index.totalSessionCount, tint: Wasteland.cyan)
                    smartRow("Bugün", "sun.max", .today, count: index.todayCount, tint: Wasteland.acid)
                    smartRow("Sabitlenenler", "pin", .pinned, count: pinnedCount, tint: Wasteland.acid)

                    sectionHeader("Projeler (\(index.projects.count))")
                    ForEach(index.projects) { project in
                        projectRow(project)
                    }
                }
                .padding(8)
            }
            Divider().overlay(Wasteland.border)
            Button {
                Task { await index.rescan() }
            } label: {
                Label("Yeniden tara", systemImage: "arrow.clockwise")
                    .font(Wasteland.font(12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .tint(Wasteland.accent)
            .padding(8)
            .disabled(index.isScanning)
        }
        .background(Wasteland.base)
        .overlay {
            if index.isScanning {
                VStack(spacing: 8) {
                    ProgressView().tint(Wasteland.accent)
                    Text("Taranıyor…").font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
                }
            } else if index.projects.isEmpty {
                ContentUnavailableView("Proje yok", systemImage: "folder", description: Text("Yeniden tara'ya bas"))
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Wasteland.font(10, weight: .semibold))
            .foregroundStyle(Wasteland.textDim)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isSelected(_ item: IndexCoordinator.SidebarItem) -> Bool {
        index.sidebarSelection == item
    }

    private var pinnedCount: Int { index.metaStore.metas.values.filter { $0.pinned }.count }

    private func smartRow(_ title: String, _ icon: String, _ item: IndexCoordinator.SidebarItem,
                          count: Int? = nil, tint: Color = Wasteland.textDim) -> some View {
        let selected = isSelected(item)
        return rowShell(selected: selected) { index.sidebarSelection = item } label: {
            HStack(spacing: 6) {
                // Tinted icon (white on the selected row) so the smart lists read at a glance.
                Image(systemName: icon)
                    .foregroundStyle(selected ? Wasteland.base : tint)
                    .frame(width: 17)
                Text(title).font(Wasteland.font(12))
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)").font(Wasteland.font(10))
                        .foregroundStyle(selected ? Wasteland.base.opacity(0.85) : Wasteland.textDim)
                }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        rowShell(selected: isSelected(.project(project.id))) {
            index.sidebarSelection = .project(project.id)
        } label: {
            ProjectRow(project: project)
        }
        // Discoverable pin-on-hover, matching session rows: keep a frequent project on top
        // without hunting for the right-click menu.
        .overlay(alignment: .trailing) {
            if hoveredProject == project.id {
                Button { index.toggleProjectPin(project.id) } label: {
                    Image(systemName: project.pinned ? "pin.slash.fill" : "pin.fill").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Wasteland.acid)
                .padding(.trailing, 8)
                .background(Wasteland.surfaceHi, in: Capsule())
                .help(project.pinned ? "Sabitlemeyi kaldır" : "Projeyi sabitle")
            }
        }
        .onHover { hoveredProject = $0 ? project.id : (hoveredProject == project.id ? nil : hoveredProject) }
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
                .foregroundStyle(selected ? Wasteland.base : Wasteland.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? Wasteland.accent : Color.clear,
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
            // Folder tinted with the project's stable colour — the same hue its sessions
            // carry as a stripe in the list, so the sidebar and list read as one palette.
            Image(systemName: project.exists ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(project.exists ? ProjectPalette.color(for: project.decodedPath) : Wasteland.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName).font(Wasteland.font(12)).lineLimit(1)
                // Relative "last touched" time reads friendlier than a long path (which
                // stays available in the hover tooltip), and shows what's fresh at a glance.
                if let date = project.lastActivity {
                    Label { Text(date, format: .relative(presentation: .named)) }
                          icon: { Image(systemName: "clock") }
                        .font(Wasteland.font(9)).foregroundStyle(Wasteland.textDim).lineLimit(1)
                } else {
                    Text(project.decodedPath)
                        .font(Wasteland.font(9)).foregroundStyle(Wasteland.textDim)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if project.pinned {
                Image(systemName: "pin.fill").font(Wasteland.font(9)).foregroundStyle(Wasteland.acid)
            }
            Text("\(project.sessionCount)").font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
        }
        .help(project.decodedPath)
    }
}
