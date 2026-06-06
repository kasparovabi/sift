import SwiftUI
import ClaudeOSBrain

/// The "Beyin" desktop window: browse/search atoms, inspect provenance, manage
/// importance, and trigger the Forgetter sweep.
public struct BrainView: View {
    @Environment(BrainViewModel.self) private var vm
    @State private var forgottenCount: Int? = nil
    @State private var mode: BrainMode =
        ProcessInfo.processInfo.environment["CLAUDEOS_BRAIN_GRAPH"] == "1" ? .graph : .list

    enum BrainMode: String, CaseIterable { case list = "Liste", graph = "Ağ" }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            switch mode {
            case .list:
                HSplitView {
                    listPane
                        .frame(minWidth: 200, idealWidth: 360, maxHeight: .infinity)
                    detailPane
                        .frame(minWidth: 120, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .graph:
                NeuralBrainView(entities: graphNodes, edges: graphEdges, onSelect: focusEntity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { Task { await vm.reload() } }
    }

    // MARK: - Graph data

    private var graphNodes: [Entity] {
        let connected = Set(vm.relations.flatMap { [$0.from, $0.to] })
        let pool = connected.isEmpty ? vm.entities : vm.entities.filter { connected.contains($0.id) }
        return Array(pool.prefix(140))
    }
    private var graphEdges: [(from: String, to: String)] {
        let ids = Set(graphNodes.map(\.id))
        return vm.relations
            .filter { ids.contains($0.from) && ids.contains($0.to) }
            .map { (from: $0.from, to: $0.to) }
    }
    private func focusEntity(_ entity: Entity) {
        vm.query = entity.n
        mode = .list
        Task { await vm.runSearch() }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            atomList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchBar: some View {
        @Bindable var bvm = vm
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Ara…", text: $bvm.query)
                .textFieldStyle(.plain)
                .onSubmit { Task { await vm.runSearch() } }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    Task { await vm.reload() }
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
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Detail pane

    @ViewBuilder private var detailPane: some View {
        if let atom = vm.selectedAtom() {
            AtomDetail(atom: atom, vm: vm)
                .id(atom.id)
        } else {
            ContentUnavailableView(
                "Bir atom seç",
                systemImage: "brain",
                description: Text("Soldan bir atom seç, detayları ve kaynağı burada görürsün.")
            )
        }
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain")
                .foregroundStyle(.purple)
            Label("\(vm.atoms.count) atom", systemImage: "circle.grid.3x3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("\(vm.entities.count) varlık", systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $mode) {
                ForEach(BrainMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            Spacer()
            Button {
                Task {
                    let n = await vm.forget()
                    forgottenCount = n
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    forgottenCount = nil
                }
            } label: {
                if let n = forgottenCount {
                    Label("\(n) silindi", systemImage: "trash").foregroundStyle(.orange)
                } else {
                    Label("Unut", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Düşük önemli, eski ve hiç erişilmemiş atomları temizle")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.ultraThinMaterial)
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
                                Task { await vm.setImportance(id: atom.id, imp: newVal) }
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
                        Task { await vm.delete(id: atom.id) }
                    } label: {
                        Label("Sil", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await vm.invalidate(id: atom.id) }
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
