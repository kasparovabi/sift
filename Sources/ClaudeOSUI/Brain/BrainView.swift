import SwiftUI
import ClaudeOSBrain

/// The "Beyin" desktop window: browse/search atoms, inspect provenance, manage
/// importance, and trigger the Forgetter sweep.
public struct BrainView: View {
    @Environment(BrainViewModel.self) private var vm
    @State private var forgottenCount: Int? = nil

    public init() {}

    public var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 300, idealWidth: 360)
            detailPane
                .frame(minWidth: 240)
        }
        .toolbar { toolbarContent }
        .onAppear { vm.reload() }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            atomList
        }
    }

    private var searchBar: some View {
        @Bindable var bvm = vm
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Ara…", text: $bvm.query)
                .textFieldStyle(.plain)
                .onSubmit { vm.runSearch() }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    vm.reload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }

    private var atomList: some View {
        @Bindable var bvm = vm
        return List(vm.atoms, selection: $bvm.selectedAtomId) { atom in
            AtomRow(atom: atom)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail pane

    @ViewBuilder private var detailPane: some View {
        if let atom = vm.selectedAtom() {
            AtomDetail(atom: atom, vm: vm)
        } else {
            ContentUnavailableView(
                "Bir atom seç",
                systemImage: "brain",
                description: Text("Soldan bir atom seç, detayları ve kaynağı burada görürsün.")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 8) {
                Label("\(vm.atoms.count) atom", systemImage: "circle.grid.3x3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("\(vm.entities.count) varlık", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                let n = vm.forget()
                forgottenCount = n
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    forgottenCount = nil
                }
            } label: {
                if let n = forgottenCount {
                    Label("\(n) silindi", systemImage: "trash")
                        .foregroundStyle(.orange)
                } else {
                    Label("Unut (temizle)", systemImage: "trash")
                }
            }
            .help("Düşük önemli, eski ve hiç erişilmemiş atomları temizle")
        }
    }
}

// MARK: - Row

private struct AtomRow: View {
    let atom: Atom

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            typeBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(atom.s)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    importanceDots(atom.imp)
                    if let proj = atom.proj, !proj.isEmpty {
                        Text(proj)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var typeBadge: some View {
        Text(atom.t.rawValue)
            .font(.caption2.monospaced().bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(badgeColor(atom.t).opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(badgeColor(atom.t))
            .frame(width: 24)
    }

    private func badgeColor(_ t: AtomType) -> Color {
        switch t {
        case .fact:     return .blue
        case .decision: return .orange
        case .pref:     return .purple
        case .entity:   return .green
        case .howto:    return .teal
        case .event:    return .pink
        }
    }

    private func importanceDots(_ imp: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(1...10, id: \.self) { i in
                Circle()
                    .frame(width: 4, height: 4)
                    .foregroundStyle(i <= imp ? Color.accentColor : Color.secondary.opacity(0.25))
            }
        }
    }
}

// MARK: - Detail

private struct AtomDetail: View {
    let atom: Atom
    let vm: BrainViewModel
    @State private var importance: Int

    init(atom: Atom, vm: BrainViewModel) {
        self.atom = atom
        self.vm = vm
        self._importance = State(initialValue: atom.imp)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(atom.s)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Tip") {
                        Text(typeLabel(atom.t))
                            .foregroundStyle(typeColor(atom.t))
                    }
                    LabeledContent("Önem") {
                        Stepper("\(importance)", value: $importance, in: 1...10, step: 1)
                            .onChange(of: importance) { _, newVal in
                                vm.setImportance(id: atom.id, imp: newVal)
                            }
                    }
                    if let proj = atom.proj, !proj.isEmpty {
                        LabeledContent("Proje", value: proj)
                    }
                    LabeledContent("Kaynak", value: atom.src)
                    LabeledContent("Oluşturulma") {
                        Text(Date(timeIntervalSince1970: atom.createdAt),
                             format: .dateTime.day().month().year().hour().minute())
                    }
                    LabeledContent("Alımlar", value: "\(atom.retrievals)")
                    if atom.invalidAt != nil {
                        Label("Geçersiz kılındı", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
                .font(.callout)

                Divider()

                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        vm.delete(id: atom.id)
                    } label: {
                        Label("Sil", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        vm.invalidate(id: atom.id)
                    } label: {
                        Label("Geçersiz kıl", systemImage: "xmark.seal")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
        }
    }

    private func typeLabel(_ t: AtomType) -> String {
        switch t {
        case .fact:     return "Gerçek (F)"
        case .decision: return "Karar (D)"
        case .pref:     return "Tercih (P)"
        case .entity:   return "Varlık (E)"
        case .howto:    return "Nasıl (H)"
        case .event:    return "Olay (V)"
        }
    }

    private func typeColor(_ t: AtomType) -> Color {
        switch t {
        case .fact:     return .blue
        case .decision: return .orange
        case .pref:     return .purple
        case .entity:   return .green
        case .howto:    return .teal
        case .event:    return .pink
        }
    }
}
