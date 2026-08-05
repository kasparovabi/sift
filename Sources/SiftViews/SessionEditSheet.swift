import SwiftUI
import SiftCore
import SiftIndex

/// Edit a session's custom name and tags. Stored in SessionMetaStore, separate
/// from the rebuildable index.
struct SessionEditSheet: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(\.dismiss) private var dismiss
    let session: SessionSummary

    @State private var name = ""
    @State private var tags: [String] = []
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit session")
                .font(Palette.font(15, weight: .bold))
                .foregroundStyle(Palette.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Ad")
                    .font(Palette.font(11))
                    .foregroundStyle(Palette.textDim)
                TextField(session.title ?? "Session name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Palette.font(12))
                    .foregroundStyle(Palette.textPrimary)
                    .onSubmit(save)
                Text("Leave empty to use the automatic title.")
                    .font(Palette.font(10))
                    .foregroundStyle(Palette.textDim)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Etiketler")
                    .font(Palette.font(11))
                    .foregroundStyle(Palette.textDim)
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text(tag)
                                        .font(Palette.font(11))
                                        .foregroundStyle(Palette.accent)
                                    Button { tags.removeAll { $0 == tag } } label: {
                                        Image(systemName: "xmark.circle.fill").font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Palette.textDim)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Palette.accent.opacity(0.15), in: Capsule())
                                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                            }
                        }
                    }
                }
                HStack {
                    TextField("Add tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .font(Palette.font(12))
                        .foregroundStyle(Palette.textPrimary)
                        .onSubmit(addTag)
                    Button("Add", action: addTag)
                        .tint(Palette.accent)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .tint(Palette.textDim)
                Button("Save", action: save)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
        .padding(18)
        .frame(width: 430, height: 340)
        .background(Palette.base)
        .onAppear {
            let meta = index.meta(for: session.sessionId)
            name = meta.name ?? ""
            tags = meta.tags
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
    }

    private func save() {
        index.rename(session.sessionId, to: name)
        index.setTags(tags, for: session.sessionId)
        dismiss()
    }
}
