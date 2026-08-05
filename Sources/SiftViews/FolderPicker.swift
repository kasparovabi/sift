import AppKit

/// Presents a native folder chooser for starting a claude session anywhere.
/// Returns nil if the user cancels.
@MainActor
func chooseClaudeDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open session"
    panel.message = "Choose the folder to start the claude session in"
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    return panel.runModal() == .OK ? panel.url : nil
}
