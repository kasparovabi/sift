import SwiftUI
import AppKit
import SiftCore
import SiftRuntime

/// "My folders": a short list of folders you return to. Tap "Open" and a fresh Claude
/// session starts right there, so you never dig through the folder picker twice.
struct FoldersView: View {
    @Environment(SessionRuntime.self) private var runtime

    private let accent = Palette.accent

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if runtime.folderBookmarks.isEmpty {
                        emptyState
                    } else {
                        Text("Press Open on a folder to start a new session there.")
                            .font(Palette.font(11)).foregroundStyle(Palette.textDim)
                        ForEach(runtime.folderBookmarks) { bookmark in folderRow(bookmark) }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.base)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(accent)
            Text("My folders").font(Palette.font(15, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            Spacer()
            Button { addFolder() } label: { Label("Add folder", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Palette.accent)
        }
        .padding(.horizontal, 14).frame(height: 44).background(Palette.surface)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus").font(.system(size: 38)).foregroundStyle(Palette.textDim)
            Text("No folders yet").font(Palette.font(13, weight: .medium)).foregroundStyle(Palette.textPrimary)
            Text("Add folders you work in often and start a session there in one click.")
                .font(Palette.font(11)).foregroundStyle(Palette.textDim).multilineTextAlignment(.center)
            Button { addFolder() } label: { Label("Add folder", systemImage: "plus") }
                .buttonStyle(.bordered).controlSize(.small).tint(Palette.accent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private func folderRow(_ bookmark: FolderBookmark) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20)).foregroundStyle(accent).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.name).font(Palette.font(13, weight: .medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(prettyPath(bookmark.path)).font(Palette.font(10)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { start(bookmark) } label: { Label("Open", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Palette.accent)
            Button(role: .destructive) { runtime.removeFolderBookmark(bookmark.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small).tint(Palette.danger)
            .help("Remove from list")
        }
        .padding(10)
        .siftPanel(cornerRadius: 10)
    }

    /// Shorten the home prefix to ~ so paths read cleanly.
    private func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func addFolder() {
        if let url = chooseClaudeDirectory() { runtime.addFolderBookmark(path: url.path) }
    }

    private func start(_ bookmark: FolderBookmark) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: bookmark.path, projectId: "", title: bookmark.name))
        }
    }
}
