import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex

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
            Text("Oturumu düzenle")
                .font(Wasteland.font(15, weight: .bold))
                .foregroundStyle(Wasteland.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Ad")
                    .font(Wasteland.font(11))
                    .foregroundStyle(Wasteland.textDim)
                TextField(session.title ?? "Oturum adı", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Wasteland.font(12))
                    .foregroundStyle(Wasteland.textPrimary)
                    .onSubmit(save)
                Text("Boş bırakırsan otomatik başlık kullanılır.")
                    .font(Wasteland.font(10))
                    .foregroundStyle(Wasteland.textDim)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Etiketler")
                    .font(Wasteland.font(11))
                    .foregroundStyle(Wasteland.textDim)
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text(tag)
                                        .font(Wasteland.font(11))
                                        .foregroundStyle(Wasteland.accent)
                                    Button { tags.removeAll { $0 == tag } } label: {
                                        Image(systemName: "xmark.circle.fill").font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Wasteland.textDim)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Wasteland.accent.opacity(0.15), in: Capsule())
                                .overlay(Capsule().strokeBorder(Wasteland.border, lineWidth: 1))
                            }
                        }
                    }
                }
                HStack {
                    TextField("Etiket ekle", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .font(Wasteland.font(12))
                        .foregroundStyle(Wasteland.textPrimary)
                        .onSubmit(addTag)
                    Button("Ekle", action: addTag)
                        .tint(Wasteland.accent)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("İptal") { dismiss() }
                    .tint(Wasteland.textDim)
                Button("Kaydet", action: save)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .tint(Wasteland.accent)
            }
        }
        .padding(18)
        .frame(width: 430, height: 340)
        .background(Wasteland.base)
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
