import SwiftUI
import AppKit
import Observation

/// In-app toast notifications. Call `post(…)` and a small card slides in at the top-right
/// of the screen, then auto-dismisses. Rendered in a dedicated click-through, top-most
/// panel so it floats above the emulated child windows without stealing focus or blocking
/// clicks — the same reason QuickOpen uses its own panel.
@MainActor
@Observable
public final class ToastCenter {
    public struct Toast: Identifiable, Equatable {
        public let id = UUID()
        let message: String
        let icon: String
        let tint: Color
    }

    public private(set) var toasts: [Toast] = []
    @ObservationIgnored private lazy var presenter = ToastPresenter(center: self)

    public init() {}

    public func post(_ message: String, icon: String = "bell.fill",
                     tint: Color = Wasteland.accent, duration: Double = 4.2) {
        presenter.ensureVisible()
        let toast = Toast(message: message, icon: icon, tint: tint)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toasts.append(toast)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            withAnimation(.easeOut(duration: 0.3)) {
                toasts.removeAll { $0.id == toast.id }
            }
        }
    }
}

/// Owns the borderless, click-through, top-most panel that hosts the toast stack.
@MainActor
final class ToastPresenter {
    private unowned let center: ToastCenter
    private var panel: NSPanel?

    init(center: ToastCenter) { self.center = center }

    func ensureVisible() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main { panel.setFrame(screen.frame, display: false) }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true          // click-through: never blocks the desktop
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let host = NSHostingView(rootView: ToastOverlay(center: center))
        host.frame = panel.frame
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

/// The toast stack, top-right, newest at the top. Observes `ToastCenter` so it animates
/// as toasts come and go.
struct ToastOverlay: View {
    let center: ToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                HStack(spacing: 11) {
                    Image(systemName: toast.icon).font(Wasteland.font(17)).foregroundStyle(toast.tint)
                    Text(toast.message).font(Wasteland.font(13, weight: .medium)).foregroundStyle(Wasteland.textPrimary).lineLimit(2)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Wasteland.surface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(toast.tint.opacity(0.55), lineWidth: 1))
                .shadow(color: Wasteland.base.opacity(0.5), radius: 12, y: 5)
                .frame(maxWidth: 360, alignment: .trailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 40).padding(.trailing, 18)
    }
}
