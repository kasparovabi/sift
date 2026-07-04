import SwiftUI
import ClaudeOSRuntime

/// One free-floating desktop note: a solid pastel card with a thin drag strip on top
/// (move handle + colour + delete) and an editable body below. The fill is a plain solid
/// colour, never a material, so dragging the card across the wallpaper stays flicker-free.
struct StickyNoteView: View {
    let note: StickyNote
    let manager: DesktopWindowManager

    @State private var hovering = false
    @State private var dragOffset: CGSize = .zero

    private var color: Color {
        let c = note.rgb
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    private var currentText: String {
        manager.stickyNotes.first { $0.id == note.id }?.text ?? note.text
    }

    var body: some View {
        VStack(spacing: 0) {
            handle
            TextEditor(text: textBinding)
                .font(Wasteland.font(13))
                .foregroundStyle(Wasteland.textPrimary)
                .tint(Wasteland.acid)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7).padding(.bottom, 7)
                .overlay(alignment: .topLeading) {
                    if currentText.isEmpty {
                        Text("Not yaz…")
                            .font(Wasteland.font(13)).foregroundStyle(Wasteland.textDim)
                            .padding(.horizontal, 12).padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
        }
        .frame(width: 176, height: 150)
        .background(Wasteland.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.7)))
        .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 3)
        .offset(dragOffset)
        .onHover { hovering = $0 }
    }

    private var handle: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Wasteland.textDim)
            Spacer(minLength: 0)
            if hovering {
                Button { manager.cycleNoteColor(note.id) } label: {
                    Image(systemName: "paintpalette.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(Wasteland.accent)
                .help("Rengi değiştir")
                Button { manager.removeNote(note.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(Wasteland.danger)
                .help("Notu sil")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .frame(maxWidth: .infinity)
        .background(Wasteland.surfaceHi)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { dragOffset = $0.translation }
                .onEnded { value in
                    manager.moveNote(note.id, to: CGPoint(x: note.x + value.translation.width,
                                                          y: note.y + value.translation.height))
                    dragOffset = .zero
                }
        )
    }

    private var textBinding: Binding<String> {
        Binding(get: { currentText },
                set: { manager.setNoteText(note.id, $0) })
    }
}
