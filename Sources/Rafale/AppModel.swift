import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var items: [QueueItem] = [] { didSet { saveSession() } }
    @Published var selection = Set<UUID>()
    /// Groupe dont l'en-tête est sélectionné : son script s'affiche dans les détails.
    @Published var selectedGroup: URL?
    /// Groupes repliés, par chemin de script.
    @Published var collapsed = Set<String>()
    @Published var running = false
    @Published var summary: String?
    @Published var lists: [SavedList] = []
    /// Un script tourne en administrateur, sauf ceux-ci (par chemin) qui tournent en utilisateur.
    @Published var userScripts: Set<String> = [] {
        didSet {
            guard !DemoData.isEnabled else { return }
            UserDefaults.standard.set(userScripts.sorted(), forKey: "userScripts")
        }
    }
    /// Arguments passés à chaque script, par chemin.
    @Published var scriptArgs: [String: String] = [:] {
        didSet {
            guard !DemoData.isEnabled else { return }
            UserDefaults.standard.set(scriptArgs, forKey: "scriptArgs")
        }
    }
    /// Scripts déposés seuls, en attente de l'installeur qu'ils accompagnent.
    private var pendingScripts: [URL] = []

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
            if let script = DemoData.selectedGroup {
                selectedGroup = script
                selection = Set(demo.items.filter { $0.script == script }.map(\.id))
            }
            lists = DemoData.lists
            userScripts = DemoData.userScripts
            scriptArgs = DemoData.scriptArgs
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
        userScripts = Set(UserDefaults.standard.stringArray(forKey: "userScripts") ?? [])
        scriptArgs = UserDefaults.standard.dictionary(forKey: "scriptArgs") as? [String: String] ?? [:]
        let scripts = UserDefaults.standard.dictionary(forKey: "sessionScripts") as? [String: String] ?? [:]
        restoring = true
        append(Self.found(paths, scripts: scripts))
        restoring = false
    }

    // MARK: File d'attente

    /// Ajoute des fichiers ou des dossiers ; les dossiers sont parcourus en entier.
    func add(_ urls: [URL]) {
        if DemoData.isEnabled { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let (found, loose) = Self.expand(urls)
            DispatchQueue.main.async {
                self.append(found)
                self.attach(loose)
            }
        }
    }

    /// Un installeur trouvé, avec le script de post-installation repéré à côté de lui.
    struct Found {
        var url: URL
        var script: URL?
    }

    /// Fichiers d'une session ou d'une liste enregistrée, avec leurs scripts s'ils existent encore.
    private static func found(_ paths: [String], scripts: [String: String]) -> [Found] {
        let fm = FileManager.default
        return paths.filter { fm.fileExists(atPath: $0) }.map { path in
            Found(url: URL(fileURLWithPath: path),
                  script: scripts[path].flatMap { fm.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil })
        }
    }

    /// Rend les installeurs avec leur script, et les scripts déposés seuls.
    nonisolated private static func expand(_ urls: [URL]) -> (found: [Found], loose: [URL]) {
        var out: [Found] = []
        var loose: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if SourceKind.of(url) != nil {
                out.append(Found(url: url, script: PostScript.namesake(of: url)))
                continue
            }
            guard isDir.boolValue else {
                if PostScript.isScript(url) { loose.append(url) }
                continue
            }
            guard url.pathExtension.lowercased() != "app" else { continue }
            var installers: [URL] = []
            var scripts: [String: [URL]] = [:]
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let u = walker?.nextObject() as? URL {
                if SourceKind.of(u) != nil {
                    installers.append(u)
                    walker?.skipDescendants()
                } else if u.pathExtension.lowercased() == "app" {
                    walker?.skipDescendants()
                } else if PostScript.isScript(u) {
                    scripts[u.deletingLastPathComponent().path, default: []].append(u)
                }
            }
            out += installers.map { Found(url: $0, script: PostScript.pick(for: $0, among: scripts, root: url.path)) }
        }
        return (out, loose)
    }

    private func append(_ found: [Found]) {
        var seen = Set(items.map { $0.url.standardizedFileURL.path })
        var fresh: [QueueItem] = []
        for f in found {
            let path = f.url.standardizedFileURL.path
            if seen.contains(path) {
                // Déjà dans la file : on lui donne seulement le script qu'on vient de lui trouver.
                if let script = f.script, !running,
                   let item = (items + fresh).first(where: { $0.url.standardizedFileURL.path == path }),
                   item.script == nil { item.script = script }
                continue
            }
            guard let kind = SourceKind.of(f.url) else { continue }
            seen.insert(path)
            let item = QueueItem(url: f.url, kind: kind)
            item.script = f.script
            fresh.append(item)
        }
        guard !fresh.isEmpty else { saveSession(); return }
        summary = nil
        for item in fresh {
            // Les compteurs de la barre d'état suivent chaque élément.
            watchers[item.id] = item.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        items.append(contentsOf: fresh)
        fresh.forEach(analyze)
        attach([])
    }

    // MARK: Scripts de post-installation

    /// Rattache des scripts déposés seuls : à l'installeur du même dossier qui porte leur nom,
    /// sinon à tous ceux de ce dossier, sinon aux lignes sélectionnées. Ceux qui ne trouvent
    /// personne attendent l'arrivée de leur installeur.
    private func attach(_ dropped: [URL]) {
        guard !running else { return }
        for script in pendingScripts + dropped {
            let dir = script.deletingLastPathComponent().standardizedFileURL.path
            var targets = items.filter { $0.url.deletingLastPathComponent().standardizedFileURL.path == dir }
            let namesakes = targets.filter { PostScript.isNamesake(script, of: $0.url) }
            if !namesakes.isEmpty { targets = namesakes }
            if targets.isEmpty, dropped.contains(script) { targets = selectedItems }
            if targets.isEmpty {
                if !pendingScripts.contains(script) { pendingScripts.append(script) }
            } else {
                targets.forEach { $0.script = script }
                pendingScripts.removeAll { $0 == script }
            }
        }
        if dropped.contains(where: pendingScripts.contains) {
            summary = L("Script en attente : déposez son installeur, ou sélectionnez une ligne avant de déposer le script.")
        }
        saveSession()
    }

    func chooseScript(for ids: Set<UUID>) {
        guard !running, !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L("Choisir")
        panel.message = L("Choisissez le script à exécuter une fois l'installation réussie.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        for item in items where ids.contains(item.id) { item.script = url }
        saveSession()
    }

    func removeScript(for ids: Set<UUID>) {
        guard !running else { return }
        for item in items where ids.contains(item.id) { item.script = nil }
        refreshGroupSelection()
        saveSession()
    }

    func runsAsRoot(_ script: URL) -> Bool { !userScripts.contains(script.path) }

    func setRoot(_ on: Bool, for script: URL) {
        if on { userScripts.remove(script.path) } else { userScripts.insert(script.path) }
    }

    func arguments(for script: URL) -> String { scriptArgs[script.path] ?? "" }

    func setArguments(_ text: String, for script: URL) {
        scriptArgs[script.path] = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
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

    /// Réglage : ne plus écarter ni signaler ce que Gatekeeper refuserait.
    static var ignoreGatekeeper: Bool { UserDefaults.standard.bool(forKey: "ignoreGatekeeper") }

    /// Le réglage vient de changer : les éléments non signés encore en attente suivent.
    func gatekeeperSettingChanged() {
        for item in items where item.state == .ready && !item.trust.ok { item.enabled = Self.checkedByDefault(item) }
    }

    /// Coché d'office : ce qui apporte quelque chose et que Gatekeeper accepterait.
    private static func checkedByDefault(_ item: QueueItem) -> Bool {
        if item.isManual { return true }
        guard item.isInstallable, item.trust.ok || ignoreGatekeeper else { return false }
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
        refreshGroupSelection()
    }

    // MARK: Groupes

    /// Un script porté par plusieurs installeurs forme un groupe : il s'exécute une seule
    /// fois, après le dernier d'entre eux. Dans l'ordre où ils apparaissent dans la file.
    var groups: [(script: URL, items: [QueueItem])] {
        var order: [URL] = [], members: [URL: [QueueItem]] = [:]
        for item in items {
            guard let script = item.script else { continue }
            if members[script] == nil { order.append(script) }
            members[script, default: []].append(item)
        }
        return order.compactMap { script in
            guard let list = members[script], list.count > 1 else { return nil }
            return (script, list)
        }
    }

    func members(of script: URL) -> [QueueItem] { items.filter { $0.script == script } }

    func isGrouped(_ item: QueueItem) -> Bool {
        guard let script = item.script else { return false }
        return items.contains { $0 !== item && $0.script == script }
    }

    /// Nom affiché d'un groupe : le dossier où se trouve son script.
    static func groupName(_ script: URL) -> String { script.deletingLastPathComponent().lastPathComponent }

    func selectGroup(_ script: URL) {
        selection = Set(members(of: script).map(\.id))
        selectedGroup = script
    }

    func toggleCollapsed(_ script: URL) {
        if collapsed.contains(script.path) { collapsed.remove(script.path) } else { collapsed.insert(script.path) }
    }

    /// Un groupe qui n'a plus au moins deux installeurs n'est plus un groupe.
    private func refreshGroupSelection() {
        if let g = selectedGroup, members(of: g).count < 2 { selectedGroup = nil }
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
            case "script":
                return (a.script?.lastPathComponent ?? "\u{FFFF}")
                    .localizedStandardCompare(b.script?.lastPathComponent ?? "\u{FFFF}") == .orderedAscending
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
        if !risky.isEmpty, !Self.ignoreGatekeeper {
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
            let o = await runner.run(todo, manual: manual, quitRunningApps: quitApps, trashSources: trash,
                                     userScripts: self.userScripts, scriptArgs: self.scriptArgs)
            self.running = false
            self.runner = nil
            var parts = [L("%d installé(s)", o.done)]
            if o.failed > 0 { parts.append(L("%d en échec", o.failed)) }
            if o.scripts > 0 { parts.append(L("%d script(s) exécuté(s)", o.scripts)) }
            if o.scriptsFailed > 0 { parts.append(L("%d script(s) en échec", o.scriptsFailed)) }
            if o.skipped > 0 { parts.append(L("%d non exécuté(s)", o.skipped)) }
            if !manual.isEmpty { parts.append(L("%d à finir à la main", manual.count)) }
            self.summary = parts.joined(separator: " · ")
            NSSound(named: o.failed + o.scriptsFailed > 0 ? "Basso" : "Glass")?.play()
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
            lists[i].scripts = sessionScripts
        } else {
            lists.append(SavedList(name: name, paths: paths, scripts: sessionScripts))
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
        append(Self.found(list.paths, scripts: list.scripts ?? [:]))
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
        UserDefaults.standard.set(sessionScripts, forKey: "sessionScripts")
    }

    private var sessionScripts: [String: String] {
        var out: [String: String] = [:]
        for item in items { if let s = item.script { out[item.url.path] = s.path } }
        return out
    }
}
