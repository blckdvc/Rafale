import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Zoom.key) private var zoom = 1.0
    @AppStorage("trashSources") private var trashSources = false
    @AppStorage("showInspector") private var showInspector = true
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                emptyState
            } else {
                QueueTable(model: model, zoom: zoom)
            }
            Divider()
            statusBar
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10 * zoom)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3 * zoom, dash: [8 * zoom]))
                    .padding(6 * zoom)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.add([url]) }
                }
            }
            return true
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 240 * zoom, ideal: 320 * zoom, max: 520 * zoom)
        }
        .toolbar { toolbar }
        .background(WindowSetup())
        .frame(minWidth: 760 * zoom, minHeight: 380 * zoom)
        .onAppear { AppDelegate.openMain = { openWindow(id: "main") } }
    }

    // MARK: Barre d'outils

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { openWindow(id: "about") } label: {
                HStack(spacing: 7 * zoom) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 24 * zoom, height: 24 * zoom)
                    Text("Rafale").font(.system(size: 15 * zoom, weight: .semibold))
                }
                .padding(.horizontal, 4 * zoom)
            }
            .buttonStyle(.plain)
            .help(L("À propos de Rafale"))
        }
        // Le logo reste à gauche, toutes les actions sont calées à droite.
        ToolbarItem(placement: .principal) { Spacer() }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.pickFiles() } label: { icon("plus", "Ajouter") }
                .help(L("Ajouter des fichiers ou un dossier"))
                .disabled(model.running)

            Menu {
                if model.lists.isEmpty {
                    Text(L("Aucune liste enregistrée"))
                } else {
                    ForEach(model.lists) { list in
                        Button(L("%@ (%d fichiers)", list.name, list.paths.count)) { model.load(list) }
                    }
                }
                Divider()
                Button(L("Enregistrer la file comme liste…")) { model.askListName() }
                    .disabled(model.items.isEmpty)
                if !model.lists.isEmpty {
                    Menu(L("Supprimer une liste")) {
                        ForEach(model.lists) { list in Button(list.name) { model.delete(list) } }
                    }
                }
            } label: { icon("list.bullet.rectangle", "Listes") }
                .help(L("Listes enregistrées"))
                .disabled(model.running)

            Button { model.reveal(model.selection) } label: { icon("folder", "Afficher dans le Finder") }
                .help(L("Afficher dans le Finder"))
                .disabled(model.selection.isEmpty)

            Button { model.remove(model.selection) } label: { icon("minus.circle", "Retirer") }
                .help(L("Retirer de la file"))
                .disabled(model.selection.isEmpty || model.running)

            Button { showInspector.toggle() } label: { icon("sidebar.right", "Détails") }
                .help(L("Afficher ou masquer les détails"))

            if model.running {
                Button { model.stop() } label: {
                    Label(model.stopping ? L("Arrêt…") : L("Arrêter"), systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon).font(.system(size: 13 * zoom))
                }
                .disabled(model.stopping)
                .help(L("Termine l'opération en cours puis s'arrête"))
            } else {
                Button { model.install() } label: {
                    Label(L("Installer"), systemImage: "arrow.down.to.line")
                        .labelStyle(.titleAndIcon).font(.system(size: 13 * zoom, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canInstall)
                .help(L("Installer tout ce qui est coché"))
            }
        }
    }

    private func icon(_ symbol: String, _ title: String) -> some View {
        Label(L(title), systemImage: symbol).font(.system(size: 13 * zoom))
    }

    // MARK: File vide

    private var emptyState: some View {
        VStack(spacing: 12 * zoom) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 52 * zoom, weight: .light))
                .foregroundStyle(.secondary)
            Text(L("Déposez ici vos .dmg, .pkg et .zip"))
                .font(.system(size: 20 * zoom, weight: .semibold))
            Text(L("Ou un dossier entier : Rafale y trouve tous les installeurs, les analyse, puis les installe d'une traite avec un seul mot de passe."))
                .font(.system(size: 13 * zoom))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440 * zoom)
            Button(L("Choisir des fichiers…")) { model.pickFiles() }
                .controlSize(.large)
                .font(.system(size: 13 * zoom))
                .padding(.top, 4 * zoom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Barre d'état

    private var statusBar: some View {
        HStack(spacing: 12 * zoom) {
            if let p = model.batchProgress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total)).frame(width: 140 * zoom)
                Text(L("%d sur %d", p.done, p.total)).monospacedDigit()
            } else if let summary = model.summary {
                Text(summary)
            } else {
                Text(counts)
            }
            Spacer()
            if model.items.contains(where: { $0.state == .done }) && !model.running {
                Button(L("Retirer ce qui est installé")) { model.clearDone() }
                    .buttonStyle(.link)
            }
            Toggle(L("Mettre les fichiers installés à la corbeille"), isOn: $trashSources)
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 12 * zoom))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12 * zoom)
        .frame(height: 30 * zoom)
    }

    private var counts: String {
        if model.items.isEmpty { return L("File vide") }
        let todo = model.toInstall
        var parts = [L("%d élément(s)", model.items.count), L("%d à installer", todo.count)]
        let size = todo.reduce(Int64(0)) { $0 + max($1.installSize, $1.fileSize) }
        if size > 0 { parts.append(formatBytes(size)) }
        if model.analyzing > 0 { parts.append(L("%d en cours d'analyse", model.analyzing)) }
        return parts.joined(separator: " · ")
    }
}

/// Réglages de la fenêtre que SwiftUI n'expose pas : position mémorisée, titre masqué.
struct WindowSetup: NSViewRepresentable {
    final class Probe: NSView {
        private var done = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            window.titleVisibility = .hidden
            // La scène « main » de SwiftUI porte déjà un nom d'enregistrement automatique
            // (setFrameAutosaveName) : taille et position reviennent au lancement. Lui en
            // donner un second ferait s'écraser les deux positions enregistrées.
            if window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("main") }
        }
    }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Détails de l'élément sélectionné

struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Zoom.key) private var zoom = 1.0

    var body: some View {
        Group {
            if let item = model.selectedItems.first, model.selection.count == 1 {
                ItemDetail(item: item).id(item.id)
            } else {
                Text(model.selection.isEmpty ? L("Sélectionnez un élément pour voir ses détails")
                                             : L("%d éléments sélectionnés", model.selection.count))
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ItemDetail: View {
    @ObservedObject var item: QueueItem
    @AppStorage(Zoom.key) private var zoom = 1.0
    @State private var scripts: String?
    @State private var loadingScripts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10 * zoom) {
                HStack(spacing: 10 * zoom) {
                    Image(nsImage: item.icon).resizable().frame(width: 40 * zoom, height: 40 * zoom)
                    VStack(alignment: .leading, spacing: 2 * zoom) {
                        Text(item.displayName).font(.system(size: 15 * zoom, weight: .semibold))
                        Text(item.typeLabel).foregroundStyle(.secondary)
                    }
                }
                row("Fichier", item.url.path)
                row("Taille du fichier", formatBytes(item.fileSize))

                ForEach(item.payloads) { p in
                    Divider()
                    Text(p.name).font(.system(size: 13 * zoom, weight: .semibold))
                    row("Identifiant", p.identifier)
                    row("Version", p.version)
                    row("Déjà installé", p.installedVersion ?? L("Non"))
                    row("Destination", p.kind == .app ? p.destination : L("Décidée par le paquet"))
                    row("Taille installée", formatBytes(p.sizeBytes))
                    row("Signature", p.trustDetail.isEmpty ? p.trust.label : "\(p.trust.label) — \(p.trustDetail)")
                    if p.packages.count > 1 {
                        row("Composants", p.packages.map { "\($0.id) \($0.version)" }.joined(separator: "\n"))
                    }
                }

                ForEach(item.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                }

                if item.payloads.contains(where: { $0.kind == .pkg && $0.hasScripts }) {
                    Divider()
                    HStack {
                        Label(L("Ce paquet exécute des scripts en root"), systemImage: "terminal")
                        Spacer()
                        if loadingScripts { ProgressView().controlSize(.small) }
                        Button(scripts == nil ? L("Les lire") : L("Masquer")) {
                            if scripts == nil { loadScripts() } else { scripts = nil }
                        }
                        .disabled(loadingScripts)
                    }
                    if let scripts { codeBlock(scripts) }
                }

                if !item.log.isEmpty {
                    Divider()
                    Text(L("Journal")).font(.system(size: 13 * zoom, weight: .semibold))
                    codeBlock(item.log)
                }
            }
            .font(.system(size: 12 * zoom))
            .padding(14 * zoom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1 * zoom) {
            Text(L(title)).font(.system(size: 10.5 * zoom)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * zoom, design: .monospaced))
            .textSelection(.enabled)
            .padding(8 * zoom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6 * zoom))
    }

    private func loadScripts() {
        loadingScripts = true
        let targets = item.payloads.filter { $0.kind == .pkg && $0.hasScripts }.map(\.relativePath)
        let item = item
        DispatchQueue.global(qos: .userInitiated).async {
            var text = ""
            if let c = Container.open(item) {
                for rel in targets { text += Analyzer.scripts(of: c.root.appendingPathComponent(rel)) }
                c.close()
            }
            DispatchQueue.main.async {
                scripts = text.isEmpty ? L("Scripts illisibles.") : text
                loadingScripts = false
            }
        }
    }
}
