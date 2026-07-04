import SwiftUI
import AppKit
import ClaudeOSCore
import ClaudeOSRuntime

/// "Klasörlerim": a short list of folders you return to. Tap "Aç" and a fresh Claude
/// session starts right there, so you never dig through the folder picker twice.
struct FoldersView: View {
    @Environment(SessionRuntime.self) private var runtime

    private let accent = Wasteland.accent

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Wasteland.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if runtime.folderBookmarks.isEmpty {
                        emptyState
                    } else {
                        Text("Bir klasörün \"Aç\" düğmesine bas, orada yeni oturum başlasın.")
                            .font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
                        ForEach(runtime.folderBookmarks) { bookmark in folderRow(bookmark) }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Wasteland.base)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(accent)
            Text("Klasörlerim").font(Wasteland.font(15, weight: .semibold)).foregroundStyle(Wasteland.textPrimary)
            Spacer()
            Button { addFolder() } label: { Label("Klasör ekle", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Wasteland.accent)
        }
        .padding(.horizontal, 14).frame(height: 44).background(Wasteland.surface)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus").font(.system(size: 38)).foregroundStyle(Wasteland.textDim)
            Text("Henüz klasör yok").font(Wasteland.font(13, weight: .medium)).foregroundStyle(Wasteland.textPrimary)
            Text("Sık çalıştığın klasörleri ekle, tek tıkla orada yeni Claude oturumu aç.")
                .font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim).multilineTextAlignment(.center)
            Button { addFolder() } label: { Label("Klasör ekle", systemImage: "plus") }
                .buttonStyle(.bordered).controlSize(.small).tint(Wasteland.accent).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private func folderRow(_ bookmark: FolderBookmark) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20)).foregroundStyle(accent).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.name).font(Wasteland.font(13, weight: .medium)).foregroundStyle(Wasteland.textPrimary).lineLimit(1)
                Text(prettyPath(bookmark.path)).font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { start(bookmark) } label: { Label("Aç", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Wasteland.accent)
            Button(role: .destructive) { runtime.removeFolderBookmark(bookmark.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small).tint(Wasteland.danger)
            .help("Listeden kaldır")
        }
        .padding(10)
        .wastelandPanel(cornerRadius: 10)
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
