import SwiftUI
import AppKit
import ClaudeOSBrain

/// The "Beyin" desktop window: browse/search atoms, inspect provenance, manage
/// importance, and trigger the Forgetter sweep.
public struct BrainView: View {
    @Environment(BrainViewModel.self) private var vm
    @State private var forgottenCount: Int? = nil
    @State private var typeFilter: AtomType?
    @State private var showingAdd = false
    @State private var copied = false
    @State private var mode: BrainMode =
        ProcessInfo.processInfo.environment["CLAUDEOS_BRAIN_GRAPH"] == "1" ? .graph : .list

    enum BrainMode: String, CaseIterable { case list = "Liste", graph = "Ağ" }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(Wasteland.border)
            switch mode {
            case .list:
                HStack(spacing: 0) {
                    listPane
                        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    Divider()
                    detailPane
                        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .graph:
                NeuralBrainView(entities: graphNodes, edges: graphEdges, onSelect: focusEntity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { Task { await vm.reload() } }
        .sheet(isPresented: $showingAdd) { AddAtomSheet(vm: vm) }
    }

    // MARK: - Graph data

    private var graphNodes: [Entity] {
        // Degree per entity, so we keep the most-connected nodes (Obsidian-style hubs)
        // when capping — and the cap keeps the O(n²) layout snappy.
        var degree: [String: Int] = [:]
        for r in vm.relations where r.from != r.to {
            degree[r.from, default: 0] += 1
            degree[r.to, default: 0] += 1
        }
        let connected = Set(degree.keys)
        let pool = connected.isEmpty ? vm.entities : vm.entities.filter { connected.contains($0.id) }
        let ranked = pool.sorted { (degree[$0.id] ?? 0) > (degree[$1.id] ?? 0) }
        return Array(ranked.prefix(120))
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

    /// Copy the loaded atoms as Markdown to the clipboard (no modal — works cleanly from
    /// the emulated window, and you can paste the export anywhere).
    private func exportMarkdown() {
        let lines = vm.atoms.map { atom -> String in
            let proj = (atom.proj?.isEmpty == false) ? " · `\(atom.proj!)`" : ""
            return "- **[\(atom.t.rawValue)]** \(atom.s) _(önem \(atom.imp))_\(proj)"
        }
        let md = "# Claude OS Beyin\n\n\(vm.atoms.count) atom · \(vm.entities.count) varlık\n\n"
            + lines.joined(separator: "\n") + "\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            typeChips
            Divider()
            atomList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Wasteland.base)
    }

    /// Tappable type-filter chips: narrow the atom list to one kind (or all).
    private var typeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(nil, "Tümü", Wasteland.textDim)
                chip(.fact, "Gerçek", Wasteland.cyan)
                chip(.decision, "Karar", Wasteland.acid)
                chip(.pref, "Tercih", Wasteland.magenta)
                chip(.entity, "Varlık", Wasteland.accent)
                chip(.howto, "Nasıl", Wasteland.cyan)
                chip(.event, "Olay", Wasteland.magenta)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Wasteland.surface)
    }

    private func chip(_ type: AtomType?, _ label: String, _ color: Color) -> some View {
        let selected = typeFilter == type
        let count = (type == nil) ? vm.atoms.count : vm.atoms.filter { $0.t == type }.count
        return HStack(spacing: 4) {
            Text(label)
            // Count badge so you can see your memory's makeup at a glance ("Gerçek 42").
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(selected ? color.opacity(0.85) : Wasteland.textDim.opacity(0.65))
            }
        }
        .font(Wasteland.font(11, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(selected ? color.opacity(0.3) : Wasteland.surfaceHi.opacity(0.6), in: Capsule())
        .foregroundStyle(selected ? color : Wasteland.textDim)
        .overlay(Capsule().strokeBorder(selected ? color.opacity(0.6) : Color.clear, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { typeFilter = (typeFilter == type ? nil : type) }
    }

    private var filteredAtoms: [Atom] {
        guard let typeFilter else { return vm.atoms }
        return vm.atoms.filter { $0.t == typeFilter }
    }

    private var searchBar: some View {
        @Bindable var bvm = vm
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Wasteland.textDim)
                .font(.caption)
            TextField("Ara…", text: $bvm.query)
                .textFieldStyle(.plain)
                .font(Wasteland.font(13))
                .foregroundStyle(Wasteland.textPrimary)
                .onSubmit { Task { await vm.runSearch() } }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    Task { await vm.reload() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Wasteland.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Wasteland.surface)
    }

    private var atomList: some View {
        // Pure-SwiftUI list so the Brain window also drags without AppKit-layer flicker.
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredAtoms) { atom in
                    AtomRow(atom: atom)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(vm.selectedAtomId == atom.id
                                    ? Wasteland.accent.opacity(0.22) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.selectedAtomId = atom.id }
                    Divider().overlay(Wasteland.border).opacity(0.25)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail pane

    @ViewBuilder private var detailPane: some View {
        if let atom = vm.selectedAtom() {
            AtomDetail(atom: atom, vm: vm)
                .id(atom.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Wasteland.base)
        } else {
            ContentUnavailableView(
                "Bir atom seç",
                systemImage: "brain",
                description: Text("Soldan bir atom seç, detayları ve kaynağı burada görürsün.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Wasteland.base)
        }
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain")
                .foregroundStyle(Wasteland.magenta)
            Label("\(vm.atoms.count) atom", systemImage: "circle.grid.3x3")
                .font(Wasteland.font(11))
                .foregroundStyle(Wasteland.textDim)
            Label("\(vm.entities.count) varlık", systemImage: "person.2")
                .font(Wasteland.font(11))
                .foregroundStyle(Wasteland.textDim)
            Spacer()
            Picker("", selection: $mode) {
                ForEach(BrainMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            Spacer()
            Button { exportMarkdown() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Wasteland.accent : Wasteland.textPrimary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Beyni Markdown olarak panoya kopyala")
            Button { showingAdd = true } label: {
                Label("Ekle", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Beyne elle bilgi ekle")
            Button {
                Task {
                    let n = await vm.forget()
                    forgottenCount = n
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    forgottenCount = nil
                }
            } label: {
                if let n = forgottenCount {
                    Label("\(n) silindi", systemImage: "trash").foregroundStyle(Wasteland.acid)
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
        .background(Wasteland.surface)
    }
}

// MARK: - Row

private struct AtomRow: View {
    let atom: Atom

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(badgeColor(atom.t))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            typeBadge
            VStack(alignment: .leading, spacing: 4) {
                Text(atom.s)
                    .font(Wasteland.font(12))
                    .foregroundStyle(Wasteland.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    importanceBar(atom.imp)
                    if let proj = atom.proj, !proj.isEmpty {
                        Text(proj)
                            .font(.caption2)
                            .foregroundStyle(Wasteland.textDim)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case .fact:     return Wasteland.cyan
        case .decision: return Wasteland.acid
        case .pref:     return Wasteland.magenta
        case .entity:   return Wasteland.accent
        case .howto:    return Wasteland.cyan
        case .event:    return Wasteland.magenta
        }
    }

    /// Compact importance meter: a filled capsule track + the numeric value, instead of
    /// ten tiny dots — quicker to read at a glance.
    private func importanceBar(_ imp: Int) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(Wasteland.surfaceHi).frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(Wasteland.accent)
                        .frame(width: 44 * CGFloat(min(10, max(0, imp))) / 10, height: 4)
                }
            Text("\(imp)").font(.caption2.monospacedDigit()).foregroundStyle(Wasteland.textDim)
        }
    }
}

// MARK: - Detail

private struct AtomDetail: View {
    let atom: Atom
    let vm: BrainViewModel
    @State private var importance: Int
    @State private var linked: [Entity] = []

    init(atom: Atom, vm: BrainViewModel) {
        self.atom = atom
        self.vm = vm
        self._importance = State(initialValue: atom.imp)
    }

    private func entityColor(_ kind: String) -> Color {
        switch kind {
        case "person":      return Wasteland.magenta
        case "project":     return Wasteland.acid
        case "file":        return Wasteland.cyan
        case "tool", "lib": return Wasteland.accent
        case "concept":     return Wasteland.cyan
        default:            return Wasteland.magenta
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(atom.s)
                    .font(Wasteland.font(13))
                    .foregroundStyle(Wasteland.textPrimary)
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
                            .foregroundStyle(Wasteland.danger)
                            .font(.caption)
                    }
                }
                .font(.callout)
                .foregroundStyle(Wasteland.textPrimary)

                if !linked.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bağlı varlıklar").font(.caption).foregroundStyle(Wasteland.textDim)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(linked, id: \.id) { e in
                                    HStack(spacing: 5) {
                                        Circle().fill(entityColor(e.k)).frame(width: 6, height: 6)
                                        Text(e.n).font(.caption2)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Wasteland.surfaceHi.opacity(0.6), in: Capsule())
                                }
                            }
                        }
                    }
                }

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
        .task(id: atom.id) { linked = vm.entities(forAtom: atom.id) }
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
        case .fact:     return Wasteland.cyan
        case .decision: return Wasteland.acid
        case .pref:     return Wasteland.magenta
        case .entity:   return Wasteland.accent
        case .howto:    return Wasteland.cyan
        case .event:    return Wasteland.magenta
        }
    }
}

// MARK: - Add atom sheet

private struct AddAtomSheet: View {
    let vm: BrainViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var type: AtomType = .fact
    @State private var importance = 5

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Beyne bilgi ekle").font(Wasteland.font(15, weight: .bold)).foregroundStyle(Wasteland.textPrimary)
            TextEditor(text: $text)
                .font(Wasteland.font(13))
                .foregroundStyle(Wasteland.textPrimary)
                .frame(height: 84)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Wasteland.border))
            Picker("Tip", selection: $type) {
                Text("Gerçek").tag(AtomType.fact)
                Text("Karar").tag(AtomType.decision)
                Text("Tercih").tag(AtomType.pref)
                Text("Varlık").tag(AtomType.entity)
                Text("Nasıl").tag(AtomType.howto)
                Text("Olay").tag(AtomType.event)
            }
            Stepper("Önem: \(importance)", value: $importance, in: 1...10)
            HStack {
                Spacer()
                Button("İptal") { dismiss() }
                Button("Kaydet") {
                    let t = trimmed
                    guard !t.isEmpty else { return }
                    Task { await vm.add(text: t, type: type, importance: importance); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}
