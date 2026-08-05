import SwiftUI
import SiftCore
import SiftIndex

/// Pure-SwiftUI sidebar (ScrollView + LazyVStack, not List/NSTableView) so it tracks
/// the emulated window's drag `.offset` smoothly without AppKit-layer flicker.
struct ProjectSidebar: View {
    @Environment(IndexCoordinator.self) private var index
    @State private var hoveredProject: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Lists")
                    smartRow("All sessions", "tray.full", .all, count: index.totalSessionCount, tint: Palette.cyan)
                    smartRow("Today", "sun.max", .today, count: index.todayCount, tint: Palette.acid)
                    smartRow("Pinned", "pin", .pinned, count: pinnedCount, tint: Palette.acid)

                    sectionHeader("Projects (\(index.projects.count))")
                    ForEach(index.projects) { project in
                        projectRow(project)
                    }
                }
                .padding(8)
            }
            Divider().overlay(Palette.border)
            Button {
                Task { await index.rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(Palette.font(12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .tint(Palette.accent)
            .padding(8)
            .disabled(index.isScanning)
        }
        .background(Palette.base)
        .overlay {
            if index.isScanning {
                VStack(spacing: 8) {
                    ProgressView().tint(Palette.accent)
                    Text("Scanning…").font(Palette.font(11)).foregroundStyle(Palette.textDim)
                }
            } else if index.projects.isEmpty {
                ContentUnavailableView("No projects", systemImage: "folder", description: Text("Yeniden tara'ya bas"))
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Palette.font(10, weight: .semibold))
            .foregroundStyle(Palette.textDim)
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
                          count: Int? = nil, tint: Color = Palette.textDim) -> some View {
        let selected = isSelected(item)
        return rowShell(selected: selected) { index.sidebarSelection = item } label: {
            HStack(spacing: 6) {
                // Tinted icon (white on the selected row) so the smart lists read at a glance.
                Image(systemName: icon)
                    .foregroundStyle(selected ? Palette.base : tint)
                    .frame(width: 17)
                Text(title).font(Palette.font(12))
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)").font(Palette.font(10))
                        .foregroundStyle(selected ? Palette.base.opacity(0.85) : Palette.textDim)
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
                .foregroundStyle(Palette.acid)
                .padding(.trailing, 8)
                .background(Palette.surfaceHi, in: Capsule())
                .help(project.pinned ? "Unpin" : "Projeyi sabitle")
            }
        }
        .onHover { hoveredProject = $0 ? project.id : (hoveredProject == project.id ? nil : hoveredProject) }
        .contextMenu {
            Button(project.pinned ? "Unpin" : "Pin",
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
                .foregroundStyle(selected ? Palette.base : Palette.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? Palette.accent : Color.clear,
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
                .foregroundStyle(project.exists ? ProjectPalette.color(for: project.decodedPath) : Palette.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName).font(Palette.font(12)).lineLimit(1)
                // Relative "last touched" time reads friendlier than a long path (which
                // stays available in the hover tooltip), and shows what's fresh at a glance.
                if let date = project.lastActivity {
                    Label { Text(date, format: .relative(presentation: .named)) }
                          icon: { Image(systemName: "clock") }
                        .font(Palette.font(9)).foregroundStyle(Palette.textDim).lineLimit(1)
                } else {
                    Text(project.decodedPath)
                        .font(Palette.font(9)).foregroundStyle(Palette.textDim)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if project.pinned {
                Image(systemName: "pin.fill").font(Palette.font(9)).foregroundStyle(Palette.acid)
            }
            Text("\(project.sessionCount)").font(Palette.font(10)).foregroundStyle(Palette.textDim)
        }
        .help(project.decodedPath)
    }
}
