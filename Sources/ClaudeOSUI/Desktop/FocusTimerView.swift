import SwiftUI
import ClaudeOSRuntime

/// "Odak": a plain focus countdown. Pick a length, press Başlat, watch the ring empty,
/// get a notification when the time is up. The count lives in SessionRuntime, so it keeps
/// running while you switch to other windows.
struct FocusTimerView: View {
    @Environment(SessionRuntime.self) private var runtime

    private let presets = [5, 15, 25, 45]
    private let accent = Wasteland.accent

    private var fraction: Double {
        guard runtime.focusTotalSeconds > 0 else { return 0 }
        return Double(runtime.focusRemaining) / Double(runtime.focusTotalSeconds)
    }

    private var timeText: String {
        let s = max(0, runtime.focusRemaining)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var statusText: String {
        if runtime.focusRunning { return "odakta" }
        return runtime.focusRemaining == 0 ? "bitti" : "hazır"
    }

    var body: some View {
        VStack(spacing: 18) {
            ring
            presetRow
            buttons
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Wasteland.border, lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .neonGlow(accent, radius: 6)
                .animation(.linear(duration: 1), value: runtime.focusRemaining)
            VStack(spacing: 2) {
                Text(timeText)
                    .font(Wasteland.font(46, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Wasteland.textPrimary)
                Text(statusText)
                    .font(Wasteland.font(12))
                    .foregroundStyle(Wasteland.textDim)
            }
        }
        .frame(width: 200, height: 200)
        .padding(.top, 8)
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.self) { m in
                let selected = runtime.focusTotalSeconds == m * 60
                Button { runtime.setFocusMinutes(m) } label: {
                    Text("\(m) dk")
                        .font(Wasteland.font(13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Wasteland.accent : Wasteland.textDim)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selected ? accent.opacity(0.25) : Wasteland.surfaceHi, in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.7) : Wasteland.border))
                }
                .buttonStyle(.plain)
                .disabled(runtime.focusRunning)
                .opacity(runtime.focusRunning ? 0.4 : 1)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                if runtime.focusRunning { runtime.pauseFocus() } else { runtime.startFocus() }
            } label: {
                Label(runtime.focusRunning ? "Duraklat" : "Başlat",
                      systemImage: runtime.focusRunning ? "pause.fill" : "play.fill")
                    .font(Wasteland.font(13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(accent)
            .disabled(runtime.focusRemaining == 0)

            Button { runtime.resetFocus() } label: {
                Label("Sıfırla", systemImage: "arrow.counterclockwise")
                    .font(Wasteland.font(13))
                    .foregroundStyle(Wasteland.textDim)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Wasteland.border)
        }
    }
}
