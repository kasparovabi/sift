import SwiftUI
import SiftRuntime

/// Asked once, on the first launch that reaches a usable window.
///
/// Knowledge extraction is the one feature that spends the user's tokens and puts transcript
/// text on the wire, so it cannot be on by default. Burying it in a Settings tab is the other
/// failure: nobody opens Settings, and the feature may as well not exist. Asking plainly, once,
/// is what both problems have in common.
struct ExtractionConsentSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Build a knowledge graph from your sessions?", systemImage: "brain")
                .font(Palette.font(16, weight: .bold))
                .foregroundStyle(Palette.textPrimary)

            Text("""
                Sift can read each session you finish and pull the durable facts out of it, \
                then draw how they connect across projects.

                Doing that means sending the session to `claude -p` under your own Claude \
                account. It spends your tokens, and the transcript text goes over the network \
                to Anthropic, exactly as it would if you pasted it into Claude yourself.

                Everything else in Sift works without this. Searching, resuming, quick tasks, \
                scheduled tasks and loops all stay on your Mac either way.
                """)
                .font(Palette.font(12))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)

            Text("You can change this any time in Settings → Knowledge.")
                .font(Palette.font(11))
                .foregroundStyle(Palette.textDim)

            HStack {
                Spacer()
                Button("Not now") { answer(false) }
                Button("Turn it on") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Palette.base)
    }

    private func answer(_ enabled: Bool) {
        Preferences.knowledgeExtractionEnabled = enabled
        Preferences.knowledgeExtractionAsked = true
        dismiss()
    }
}
