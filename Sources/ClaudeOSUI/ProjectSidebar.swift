import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex

struct ProjectSidebar: View {
    @Environment(IndexCoordinator.self) private var index

    var body: some View {
        @Bindable var index = index
        let selection = Binding<IndexCoordinator.SidebarItem?>(
            get: { index.sidebarSelection },
            set: { index.sidebarSelection = $0 ?? .all }
        )
        List(selection: selection) {
            Section("Listeler") {
                Label("Tüm oturumlar", systemImage: "tray.full")
                    .tag(Optional(IndexCoordinator.SidebarItem.all))
                Label("Bugün", systemImage: "sun.max")
                    .tag(Optional(IndexCoordinator.SidebarItem.today))
                Label("Sabitlenenler", systemImage: "pin")
                    .tag(Optional(IndexCoordinator.SidebarItem.pinned))
            }
            Section {
                ForEach(index.projects) { project in
                    ProjectRow(project: project)
                        .tag(Optional(IndexCoordinator.SidebarItem.project(project.id)))
                        .contextMenu {
                            Button(project.pinned ? "Sabitlemeyi kaldır" : "Sabitle",
                                   systemImage: project.pinned ? "pin.slash" : "pin") {
                                index.toggleProjectPin(project.id)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Projeler")
                    Spacer()
                    Text("\(index.projects.count)").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
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
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await index.rescan() }
            } label: {
                Label("Yeniden tara", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(8)
            .disabled(index.isScanning)
        }
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
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("\(project.sessionCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(project.decodedPath)
    }
}
