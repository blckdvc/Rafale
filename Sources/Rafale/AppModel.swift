import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var items: [QueueItem] = [] { didSet { saveSession() } }
    @Published var selection = Set<UUID>()
    @Published var running = false
    @Published var summary: String?
    @Published var lists: [SavedList] = []

    private var runner: BatchRunner?
    private var watchers: [UUID: AnyCancellable] = [:]
    private var restoring = false
    private let analysis: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    private static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rafale")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private static let listsFile = supportDir.appendingPathComponent("lists.json")

    private init() {
        // Captures d'écran du README : file inventée, rien n'est lu ni enregistré.
        if DemoData.isEnabled {
            let demo = DemoData.queue()
            restoring = true
            items = demo.items
            for item in demo.items {
                watchers[item.id] = item.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            }
            if let selected = demo.selected { selection = [selected.id] }
            lists = DemoData.lists
            running = DemoData.stage == "running"
            summary = DemoData.summary
            return
        }
        Scratch.removeStale()
        if let data = try? Data(contentsOf: Self.listsFile),
           let saved = try? JSONDecoder().decode([SavedList].self, from: data) {
            lists = saved
        }
        // La file du dernier lancement revient telle quelle.
        let paths = UserDefaults.standard.stringArray(forKey: "session") ?? []
        restoring = true
        append(paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) })
        restoring = false
    }

    // MARK: File d'attente

    /// Ajoute des fichiers ou des dossiers ; les dossiers sont parcourus en entier.
    func add(_ urls: [URL]) {
        if DemoData.isEnabled { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.expand(urls)
            DispatchQueue.main.async { self.append(found) }
        }
    }

    nonisolated private static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if SourceKind.of(url) != nil { out.append(url); continue }
            guard isDir.boolValue, url.pathExtension.lowercased() != "app" else { continue }
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let u = walker?.nextObject() as? URL {
                if SourceKind.of(u) != nil {
                    out.append(u)
                    walker?.skipDescendants()
                } else if u.pathExtension.lowercased() == "app" {
                    walker?.skipDescendants()
                }
            }
        }
        return out
    }

    private func append(_ urls: [URL]) {
        let known = Set(items.map { $0.url.standardizedFileURL.path })
        var seen = known
        var fresh: [QueueItem] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), let kind = SourceKind.of(url) else { continue }
            seen.insert(path)
            fresh.append(QueueItem(url: url, kind: kind))
        }
        guard !fresh.isEmpty else { return }
        summary = nil
        for item in fresh {
            // Les compteurs de la barre d'état suivent chaque élément.
            watchers[item.id] = item.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        items.append(contentsOf: fresh)
        fresh.forEach(analyze)
    }

    func analyze(_ item: QueueItem) {
        if DemoData.isEnabled { return }
        item.state = .analyzing
        item.notes = []
        if let old = item.workDir { try? FileManager.default.removeItem(at: old); item.workDir = nil }
        let url = item.url, kind = item.kind
        analysis.addOperation {
            let r = Analyzer.analyze(url: url, kind: kind)
            DispatchQueue.main.async {
                item.payloads = r.payloads
                item.notes = r.notes
                item.workDir = r.workDir
                item.hasLicense = r.hasLicense
                item.state = r.state
                item.enabled = Self.checkedByDefault(item)
            }
        }
    }

    /// Coché d'office : ce qui apporte quelque chose et que Gatekeeper accepterait.
    private static func checkedByDefault(_ item: QueueItem) -> Bool {
        if item.isManual { return true }
        guard item.isInstallable, item.trust.ok else { return false }
        return item.comparison == .new || item.comparison == .update || item.comparison == .unknown
    }

    func remove(_ ids: Set<UUID>) {
        guard !running, !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            if let dir = item.workDir { try? FileManager.default.removeItem(at: dir) }
            watchers[item.id] = nil
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func clear() { remove(Set(items.map(\.id))) }

    func clearDone() { remove(Set(items.filter { $0.state == .done }.map(\.id))) }

    func setEnabled(_ on: Bool, for ids: Set<UUID>) {
        for item in items where ids.contains(item.id) && item.canToggle { item.enabled = on }
    }

    var selectedItems: [QueueItem] { items.filter { selection.contains($0.id) } }

    func reveal(_ ids: Set<UUID>) {
        let urls = items.filter { ids.contains($0.id) }.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["pkg", "mpkg", "dmg", "zip"].compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.prompt = L("Ajouter")
        panel.message = L("Choisissez des fichiers .dmg, .pkg, .zip ou un dossier qui en contient.")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func sort(by key: String, ascending: Bool) {
        func less(_ a: QueueItem, _ b: QueueItem) -> Bool {
            switch key {
            case "on": return a.enabled && !b.enabled
            case "type": return a.typeLabel.localizedStandardCompare(b.typeLabel) == .orderedAscending
            case "version": return compareVersions(a.version, b.version) == .orderedAscending
            case "installed": return a.comparison.rawValue < b.comparison.rawValue
            case "trust": return a.trust.rawValue < b.trust.rawValue
            case "size": return max(a.installSize, a.fileSize) < max(b.installSize, b.fileSize)
            case "state": return a.state.rank < b.state.rank
            default: return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
        items.sort { ascending ? less($0, $1) : less($1, $0) }
    }

    // MARK: Chiffres de la barre d'état

    var toInstall: [QueueItem] { items.filter { $0.enabled && $0.isInstallable } }
    var manualToOpen: [QueueItem] { items.filter { $0.enabled && $0.isManual } }
    var analyzing: Int { items.filter { $0.state == .analyzing }.count }
    var canInstall: Bool { !running && analyzing == 0 && (!toInstall.isEmpty || !manualToOpen.isEmpty) }

    var batchProgress: (done: Int, total: Int)? {
        guard running else { return nil }
        let batch = items.filter {
            switch $0.state { case .waiting, .running, .done, .failed, .skipped: return true; default: return false }
        }
        let over = batch.filter {
            switch $0.state { case .done, .failed, .skipped: return true; default: return false }
        }
        return (over.count, batch.count)
    }

    // MARK: Installation

    func install() {
        if DemoData.isEnabled { return }
        guard canInstall else { return }
        let todo = toInstall
        let manual = manualToOpen

        let risky = todo.filter { !$0.trust.ok }
        if !risky.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("%d élément(s) ne passeraient pas Gatekeeper", risky.count)
            alert.informativeText = risky.map { "• \($0.displayName) — \($0.trust.label)" }.joined(separator: "\n")
                + "\n\n" + L("Ils seront installés tels quels. N'acceptez que si vous connaissez leur provenance.")
            alert.addButton(withTitle: L("Annuler"))
            alert.addButton(withTitle: L("Installer quand même"))
            if alert.runModal() != .alertSecondButtonReturn { return }
        }

        var quitApps = false
        let open = todo.flatMap(\.payloads).filter {
            $0.kind == .app && !$0.identifier.isEmpty
                && !NSRunningApplication.runningApplications(withBundleIdentifier: $0.identifier).isEmpty
        }
        if !open.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("%d app(s) à remplacer sont ouvertes", open.count)
            alert.informativeText = open.map { "• \($0.name)" }.joined(separator: "\n")
            alert.addButton(withTitle: L("Les quitter et continuer"))
            alert.addButton(withTitle: L("Les laisser de côté"))
            alert.addButton(withTitle: L("Annuler"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: quitApps = true
            case .alertSecondButtonReturn: quitApps = false
            default: return
            }
        }

        let runner = BatchRunner()
        self.runner = runner
        running = true
        summary = nil
        let trash = UserDefaults.standard.bool(forKey: "trashSources")
        Task {
            let o = await runner.run(todo, manual: manual, quitRunningApps: quitApps, trashSources: trash)
            self.running = false
            self.runner = nil
            var parts = [L("%d installé(s)", o.done)]
            if o.failed > 0 { parts.append(L("%d en échec", o.failed)) }
            if o.skipped > 0 { parts.append(L("%d non exécuté(s)", o.skipped)) }
            if !manual.isEmpty { parts.append(L("%d à finir à la main", manual.count)) }
            self.summary = parts.joined(separator: " · ")
            NSSound(named: o.failed > 0 ? "Basso" : "Glass")?.play()
            if trash { self.clearDone() }
        }
    }

    func stop() { if DemoData.isEnabled { return }; runner?.stop(); objectWillChange.send() }
    var stopping: Bool { runner?.stopping ?? false }

    // MARK: Listes enregistrées

    func saveList(named name: String) {
        let paths = items.map(\.url.path)
        guard !name.isEmpty, !paths.isEmpty else { return }
        if let i = lists.firstIndex(where: { $0.name == name }) {
            lists[i].paths = paths
        } else {
            lists.append(SavedList(name: name, paths: paths))
        }
        persistLists()
    }

    func askListName() {
        let alert = NSAlert()
        alert.messageText = L("Enregistrer la file comme liste")
        alert.informativeText = L("La liste retient les fichiers de la file, pour rejouer le même lot plus tard.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("Nom de la liste")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Enregistrer"))
        alert.addButton(withTitle: L("Annuler"))
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            saveList(named: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    func load(_ list: SavedList) {
        if DemoData.isEnabled { return }
        let urls = list.paths.map { URL(fileURLWithPath: $0) }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        append(urls.filter { !missing.contains($0) })
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("%d fichier(s) de la liste sont introuvables", missing.count)
            alert.informativeText = missing.map(\.lastPathComponent).joined(separator: "\n")
            alert.runModal()
        }
    }

    func delete(_ list: SavedList) {
        lists.removeAll { $0.id == list.id }
        persistLists()
    }

    private func persistLists() {
        if DemoData.isEnabled { return }
        if let data = try? JSONEncoder().encode(lists) { try? data.write(to: Self.listsFile, options: .atomic) }
    }

    private func saveSession() {
        guard !restoring, !DemoData.isEnabled else { return }
        UserDefaults.standard.set(items.map(\.url.path), forKey: "session")
    }
}
