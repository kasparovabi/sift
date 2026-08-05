import SwiftUI
import AppKit
import SiftBrain

/// The "Knowledge" desktop window: browse/search atoms, inspect provenance, manage
/// importance, and trigger the Forgetter sweep.
public struct BrainView: View {
    @Environment(BrainViewModel.self) private var vm
    @State private var forgottenCount: Int? = nil
    @State private var typeFilter: AtomType?
    @State private var showingAdd = false
    @State private var copied = false
    @State private var mode: BrainMode =
        ProcessInfo.processInfo.environment["SIFT_BRAIN_GRAPH"] == "1" ? .graph : .list

    enum BrainMode: String, CaseIterable { case list = "List", graph = "Graph" }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(Palette.border)
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

    /// The store already returns the most-connected entities together with the edges between
    /// them, so nothing is re-filtered here. Re-deriving the node set from a separately
    /// paged entity list is what previously produced a graph with no edges at all.
    private var graphNodes: [Entity] { vm.graphEntities }

    private var graphEdges: [(from: String, to: String)] {
        vm.relations.map { (from: $0.from, to: $0.to) }
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
            return "- **[\(atom.t.rawValue)]** \(atom.s) _(weight \(atom.imp))_\(proj)"
        }
        let md = "# Sift knowledge\n\n\(vm.atoms.count) items · \(vm.entities.count) entities\n\n"
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
        .background(Palette.base)
    }

    /// Tappable type-filter chips: narrow the atom list to one kind (or all).
    private var typeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(nil, "All", Palette.textDim)
                chip(.fact, "Fact", Palette.cyan)
                chip(.decision, "Decision", Palette.acid)
                chip(.pref, "Preference", Palette.magenta)
                chip(.entity, "Entity", Palette.accent)
                chip(.howto, "How", Palette.cyan)
                chip(.event, "Event", Palette.magenta)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Palette.surface)
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
                    .foregroundStyle(selected ? color.opacity(0.85) : Palette.textDim.opacity(0.65))
            }
        }
        .font(Palette.font(11, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(selected ? color.opacity(0.3) : Palette.surfaceHi.opacity(0.6), in: Capsule())
        .foregroundStyle(selected ? color : Palette.textDim)
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
                .foregroundStyle(Palette.textDim)
                .font(.caption)
            TextField("Search…", text: $bvm.query)
                .textFieldStyle(.plain)
                .font(Palette.font(13))
                .foregroundStyle(Palette.textPrimary)
                .onSubmit { Task { await vm.runSearch() } }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    Task { await vm.reload() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.surface)
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
                                    ? Palette.accent.opacity(0.22) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.selectedAtomId = atom.id }
                    Divider().overlay(Palette.border).opacity(0.25)
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
                .background(Palette.base)
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "brain",
                description: Text("Pick an item on the left to see its detail and source here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.base)
        }
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain")
                .foregroundStyle(Palette.magenta)
            Label("\(vm.atoms.count) atom", systemImage: "circle.grid.3x3")
                .font(Palette.font(11))
                .foregroundStyle(Palette.textDim)
            Label("\(vm.entities.count) entities", systemImage: "person.2")
                .font(Palette.font(11))
                .foregroundStyle(Palette.textDim)
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
                    .foregroundStyle(copied ? Palette.accent : Palette.textPrimary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy knowledge as Markdown")
            Button { showingAdd = true } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Add knowledge manually")
            Button {
                Task {
                    let n = await vm.forget()
                    forgottenCount = n
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    forgottenCount = nil
                }
            } label: {
                if let n = forgottenCount {
                    Label("\(n) forgotten", systemImage: "trash").foregroundStyle(Palette.acid)
                } else {
                    Label("Forget", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Drop low-importance, aged, never-retrieved items")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Palette.surface)
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
                    .font(Palette.font(12))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    importanceBar(atom.imp)
                    if let proj = atom.proj, !proj.isEmpty {
                        Text(proj)
                            .font(.caption2)
                            .foregroundStyle(Palette.textDim)
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
        case .fact:     return Palette.cyan
        case .decision: return Palette.acid
        case .pref:     return Palette.magenta
        case .entity:   return Palette.accent
        case .howto:    return Palette.cyan
        case .event:    return Palette.magenta
        }
    }

    /// Compact importance meter: a filled capsule track + the numeric value, instead of
    /// ten tiny dots — quicker to read at a glance.
    private func importanceBar(_ imp: Int) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(Palette.surfaceHi).frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.accent)
                        .frame(width: 44 * CGFloat(min(10, max(0, imp))) / 10, height: 4)
                }
            Text("\(imp)").font(.caption2.monospacedDigit()).foregroundStyle(Palette.textDim)
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
        case "person":      return Palette.magenta
        case "project":     return Palette.acid
        case "file":        return Palette.cyan
        case "tool", "lib": return Palette.accent
        case "concept":     return Palette.cyan
        default:            return Palette.magenta
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(atom.s)
                    .font(Palette.font(13))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Type") {
                        Text(typeLabel(atom.t))
                            .foregroundStyle(typeColor(atom.t))
                    }
                    LabeledContent("Weight") {
                        Stepper("\(importance)", value: $importance, in: 1...10, step: 1)
                            .onChange(of: importance) { _, newVal in
                                Task { await vm.setImportance(id: atom.id, imp: newVal) }
                            }
                    }
                    if let proj = atom.proj, !proj.isEmpty {
                        LabeledContent("Project", value: proj)
                    }
                    LabeledContent("Kaynak", value: atom.src)
                    LabeledContent("Created") {
                        Text(Date(timeIntervalSince1970: atom.createdAt),
                             format: .dateTime.day().month().year().hour().minute())
                    }
                    LabeledContent("Retrievals", value: "\(atom.retrievals)")
                    if atom.invalidAt != nil {
                        Label("Superseded", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Palette.danger)
                            .font(.caption)
                    }
                }
                .font(.callout)
                .foregroundStyle(Palette.textPrimary)

                if !linked.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Linked entities").font(.caption).foregroundStyle(Palette.textDim)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(linked, id: \.id) { e in
                                    HStack(spacing: 5) {
                                        Circle().fill(entityColor(e.k)).frame(width: 6, height: 6)
                                        Text(e.n).font(.caption2)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Palette.surfaceHi.opacity(0.6), in: Capsule())
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
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await vm.invalidate(id: atom.id) }
                    } label: {
                        Label("Supersede", systemImage: "xmark.seal")
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
        case .fact:     return "Fact (F)"
        case .decision: return "Karar (D)"
        case .pref:     return "Tercih (P)"
        case .entity:   return "Entity (E)"
        case .howto:    return "How (H)"
        case .event:    return "Olay (V)"
        }
    }

    private func typeColor(_ t: AtomType) -> Color {
        switch t {
        case .fact:     return Palette.cyan
        case .decision: return Palette.acid
        case .pref:     return Palette.magenta
        case .entity:   return Palette.accent
        case .howto:    return Palette.cyan
        case .event:    return Palette.magenta
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
            Text("Add knowledge").font(Palette.font(15, weight: .bold)).foregroundStyle(Palette.textPrimary)
            TextEditor(text: $text)
                .font(Palette.font(13))
                .foregroundStyle(Palette.textPrimary)
                .frame(height: 84)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.border))
            Picker("Type", selection: $type) {
                Text("Fact").tag(AtomType.fact)
                Text("Decision").tag(AtomType.decision)
                Text("Preference").tag(AtomType.pref)
                Text("Entity").tag(AtomType.entity)
                Text("How").tag(AtomType.howto)
                Text("Event").tag(AtomType.event)
            }
            Stepper("Weight: \(importance)", value: $importance, in: 1...10)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
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
