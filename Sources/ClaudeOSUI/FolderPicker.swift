import AppKit

/// Presents a native folder chooser for starting a claude session anywhere.
/// Returns nil if the user cancels.
@MainActor
func chooseClaudeDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Oturum Aç"
    panel.message = "claude oturumunun başlatılacağı klasörü seç"
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    return panel.runModal() == .OK ? panel.url : nil
}
