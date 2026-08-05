import SwiftUI

/// Theme picker with a live sample of each design.
///
/// The sample is drawn from the theme's own tokens rather than a screenshot, so adding a
/// theme to `SiftTheme.all` is all it takes for it to appear here, correctly rendered.
struct AppearanceSettings: View {
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SiftTheme.all) { theme in
                    row(theme)
                }
            }
            .padding(16)
        }
    }

    private func row(_ theme: SiftTheme) -> some View {
        let selected = themes.theme.id == theme.id
        return Button {
            themes.theme = theme
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ThemeSample(theme: theme)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(theme.name).font(.headline)
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(theme.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A miniature of the app in one theme: title bar, a selected row, two plain rows, accents.
struct ThemeSample: View {
    let theme: SiftTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach([theme.accent, theme.cyan, theme.acid], id: \.self) { swatch in
                    Circle().fill(swatch).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            bar(width: 60, color: theme.textPrimary)
            selectedRow
            bar(width: 52, color: theme.textDim)
            bar(width: 44, color: theme.textDim)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(width: 104, height: 74, alignment: .topLeading)
        .background(theme.base, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    private var selectedRow: some View {
        bar(width: 68, color: theme.accent)
            .padding(.vertical, 2)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.selectionFill,
                        in: RoundedRectangle(cornerRadius: max(2, theme.cornerRadius - 3)))
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: width, height: 3)
    }
}
