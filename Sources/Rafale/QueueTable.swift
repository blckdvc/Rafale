import AppKit
import SwiftUI

/// Tableau de la file. NSTableView plutôt que Table : il mémorise la largeur et l'ordre
/// des colonnes, et reste fluide quel que soit le nombre de lignes.
struct QueueTable: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var zoom: Double

    static let columns: [(id: String, title: String, width: CGFloat, min: CGFloat)] = [
        ("on", "", 30, 30),
        ("name", "Nom", 220, 120),
        ("type", "Type", 95, 60),
        ("version", "Version", 80, 50),
        ("installed", "Déjà installé", 140, 80),
        ("trust", "Signature", 120, 80),
        ("size", "Taille", 75, 50),
        ("state", "État", 200, 100),
    ]

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTable()
        table.onDelete = { [weak model] in model.map { $0.remove($0.selection) } }
        table.onSpace = { [weak model] in
            guard let model else { return }
            let on = !model.selectedItems.allSatisfy(\.enabled)
            model.setEnabled(on, for: model.selection)
        }
        for c in Self.columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title.isEmpty ? "" : L(c.title)
            col.width = c.width
            col.minWidth = c.min
            if c.id == "on" { col.maxWidth = c.width }
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true)
            table.addTableColumn(col)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsColumnReordering = true
        table.autosaveName = "RafaleQueue"
        table.autosaveTableColumns = true
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync(zoom: zoom)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var table: NSTableView?
        private var shown: [UUID] = []
        private var zoom = 0.0
        private var syncing = false
        private var fitted = false

        init(model: AppModel) { self.model = model }

        func sync(zoom: Double) {
            guard let table else { return }
            let ids = model.items.map(\.id)
            if ids != shown || zoom != self.zoom {
                shown = ids
                self.zoom = zoom
                table.rowHeight = (26 * zoom).rounded()
                table.reloadData()
            }
            if !fitted, table.bounds.width > 0 {
                // Au premier affichage, les colonnes se partagent la largeur disponible.
                fitted = true
                DispatchQueue.main.async { table.sizeToFit() }
            }
            let rows = IndexSet(model.items.indices.filter { model.selection.contains(model.items[$0].id) })
            if rows != table.selectedRowIndexes {
                syncing = true
                table.selectRowIndexes(rows, byExtendingSelection: false)
                syncing = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { model.items.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, row < model.items.count else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? HostCell ?? {
                let c = HostCell()
                c.identifier = column.identifier
                return c
            }()
            cell.show(AnyView(QueueCell(item: model.items[row], column: column.identifier.rawValue, zoom: zoom)))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { $0 < model.items.count ? model.items[$0].id : nil })
            if ids != model.selection { model.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
            model.sort(by: key, ascending: d.ascending)
        }

        @objc func doubleClick() {
            guard let table, table.clickedRow >= 0, table.clickedRow < model.items.count else { return }
            model.reveal([model.items[table.clickedRow].id])
        }

        // Menu contextuel : agit sur la ligne cliquée, ou sur la sélection si elle en fait partie.
        private var target: Set<UUID> {
            guard let table, table.clickedRow >= 0, table.clickedRow < model.items.count else { return model.selection }
            let id = model.items[table.clickedRow].id
            return model.selection.contains(id) ? model.selection : [id]
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard !target.isEmpty else { return }
            let entries: [(String, Selector)] = [
                ("Afficher dans le Finder", #selector(reveal)),
                ("Cocher", #selector(check)),
                ("Décocher", #selector(uncheck)),
                ("Analyser à nouveau", #selector(reanalyze)),
                ("Retirer de la file", #selector(remove)),
            ]
            for (title, action) in entries {
                let item = NSMenuItem(title: L(title), action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        @objc private func reveal() { model.reveal(target) }
        @objc private func check() { model.setEnabled(true, for: target) }
        @objc private func uncheck() { model.setEnabled(false, for: target) }
        @objc private func remove() { model.remove(target) }
        @objc private func reanalyze() {
            guard !model.running else { return }
            let ids = target
            model.items.filter { ids.contains($0.id) }.forEach { model.analyze($0) }
        }
    }
}

final class KeyTable: NSTableView {
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()
        case 49: onSpace?()
        default: super.keyDown(with: event)
        }
    }
}

final class HostCell: NSTableCellView {
    private var host: NSHostingView<AnyView>?

    func show(_ view: AnyView) {
        if let host {
            host.rootView = view
            return
        }
        let h = NSHostingView(rootView: view)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor),
            h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor),
            h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        host = h
    }
}

/// Contenu d'une cellule ; suit l'élément en direct pendant l'installation.
struct QueueCell: View {
    @ObservedObject var item: QueueItem
    let column: String
    let zoom: Double

    private var font: Font { .system(size: 13 * zoom) }

    var body: some View {
        content
            .font(font)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: column == "size" ? .trailing : .leading)
            .opacity(item.enabled || !item.canToggle ? 1 : 0.55)
    }

    @ViewBuilder private var content: some View {
        switch column {
        case "on":
            Toggle("", isOn: $item.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .scaleEffect(zoom)
                .disabled(!item.canToggle)
        case "name":
            HStack(spacing: 6 * zoom) {
                Image(nsImage: item.icon).resizable().frame(width: 18 * zoom, height: 18 * zoom)
                Text(item.displayName)
            }
            .help(item.url.path)
        case "type":
            Text(item.typeLabel).foregroundStyle(.secondary)
        case "version":
            Text(item.version.isEmpty ? "—" : item.version).monospacedDigit()
        case "installed":
            installed
        case "trust":
            trust
        case "size":
            Text(formatBytes(item.installSize > 0 ? item.installSize : item.fileSize))
                .monospacedDigit().foregroundStyle(.secondary)
        default:
            state
        }
    }

    @ViewBuilder private var installed: some View {
        if item.payloads.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            switch item.comparison {
            case .new: Text(L("Pas encore installé")).foregroundStyle(.secondary)
            case .update: Text(L("%@ → mise à jour", item.installedVersion ?? "?")).foregroundStyle(.blue)
            case .same: Text(L("Identique")).foregroundStyle(.secondary)
            case .older: Text(L("%@, plus récent", item.installedVersion ?? "?")).foregroundStyle(.orange)
            case .unknown: Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var trust: some View {
        if item.payloads.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            let t = item.trust
            let detail = item.payloads.first?.trustDetail ?? ""
            Label(t.label, systemImage: t.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(t == .notarized ? .green : t == .signed ? .teal : t == .unnotarized ? .orange : .red)
                .help(detail.isEmpty ? t.label : detail)
        }
    }

    @ViewBuilder private var state: some View {
        switch item.state {
        case .analyzing:
            HStack(spacing: 6 * zoom) {
                ProgressView().controlSize(.small).scaleEffect(zoom)
                Text(L("Analyse…")).foregroundStyle(.secondary)
            }
        case .ready:
            Text(item.enabled ? L("Prêt") : L("Laissé de côté")).foregroundStyle(.secondary)
        case .manual(let message):
            Label(message, systemImage: "hand.point.up.left.fill").foregroundStyle(.orange).help(message)
        case .unsupported(let message):
            Label(message, systemImage: "nosign").foregroundStyle(.secondary).help(message)
        case .waiting:
            Text(L("En attente")).foregroundStyle(.secondary)
        case .running(let pct, let phase):
            HStack(spacing: 6 * zoom) {
                if pct < 0 {
                    ProgressView().controlSize(.small).scaleEffect(zoom)
                } else {
                    ProgressView(value: min(100, pct), total: 100).frame(width: 70 * zoom)
                }
                Text(phase).foregroundStyle(.secondary)
            }
        case .done:
            Label(L("Installé"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).help(message)
        case .skipped:
            Text(L("Non exécuté")).foregroundStyle(.secondary)
        }
    }
}
