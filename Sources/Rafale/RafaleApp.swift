import AppKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Renseigné par la fenêtre principale ; permet de la rouvrir depuis AppKit.
    static var openMain: (() -> Void)?

    static func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }

    // L'app reste dans la barre de menus une fois la fenêtre fermée.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showMain() }
        return true
    }

    // Fichiers déposés sur l'icône du Dock ou ouverts avec Rafale.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls) }
        Self.showMain()
    }

    func applicationWillTerminate(_ notification: Notification) { Scratch.cleanup() }
}

final class Updater {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: nil)
    func check() { controller.checkForUpdates(nil) }
}

@main
struct RafaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() { _ = Updater.shared }

    var body: some Scene {
        Window("Rafale", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 1100, height: 600)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appInfo) { AboutButton() }
            CommandGroup(after: .appInfo) {
                Button(L("Rechercher les mises à jour…")) { Updater.shared.check() }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Ajouter…")) { model.pickFiles() }
                    .keyboardShortcut("o")
                    .disabled(model.running)
                Button(L("Installer ce qui est coché")) { model.install() }
                    .keyboardShortcut(.return)
                    .disabled(!model.canInstall)
                Divider()
                Button(L("Enregistrer la file comme liste…")) { model.askListName() }
                    .keyboardShortcut("s")
                    .disabled(model.items.isEmpty)
                Button(L("Vider la file")) { model.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.items.isEmpty || model.running)
            }
            CommandGroup(after: .toolbar) {
                Button(L("Agrandir")) { Zoom.bigger() }.keyboardShortcut("+")
                Button(L("Réduire")) { Zoom.smaller() }.keyboardShortcut("-")
                Button(L("Taille réelle")) { Zoom.reset() }.keyboardShortcut("0")
                Divider()
            }
        }

        Window(L("À propos de Rafale"), id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarMenu().environmentObject(model)
        } label: {
            Image(nsImage: Self.menuIcon)
        }
    }

    private static let menuIcon: NSImage = {
        let image = Bundle.main.image(forResource: "MenuIcon") ?? NSImage(
            systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Rafale") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

private struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L("À propos de Rafale")) {
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct MenuBarMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Ouvrir Rafale")) { show() }
        Button(model.toInstall.isEmpty ? L("Installer la file")
                                       : L("Installer la file (%d)", model.toInstall.count)) {
            show()
            model.install()
        }
        .disabled(!model.canInstall)
        Button(L("Ajouter des fichiers…")) {
            show()
            model.pickFiles()
        }
        .disabled(model.running)
        Divider()
        Button(L("À propos de Rafale")) {
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(L("Rechercher les mises à jour…")) { Updater.shared.check() }
        Divider()
        Button(L("Quitter Rafale")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Zoom.key) private var zoom = 1.0

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 10 * zoom) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 112 * zoom, height: 112 * zoom)
            Text("Rafale \(version)").font(.system(size: 20 * zoom, weight: .semibold))
            Text(L("Installe d'une traite tous vos .dmg, .pkg et .zip, avec un seul mot de passe."))
                .font(.system(size: 13 * zoom))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("par blckdvc")).font(.system(size: 13 * zoom)).foregroundStyle(.secondary)

            Text(L("Libre et open source — si le cœur vous en dit, offrez-moi quelques tokens :"))
                .font(.system(size: 12 * zoom))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8 * zoom)
            Button {
                if let url = URL(string: "https://paypal.me/lbenh") { NSWorkspace.shared.open(url) }
            } label: {
                if let image = Bundle.main.image(forResource: "buy-me-tokens") {
                    Image(nsImage: image).resizable().frame(width: 179 * zoom, height: 40 * zoom)
                } else {
                    Text("Buy me tokens")
                }
            }
            .buttonStyle(.plain)

            Text(L("Inclut Sparkle, sous sa propre licence."))
                .font(.system(size: 10.5 * zoom))
                .foregroundStyle(.tertiary)
                .padding(.top, 6 * zoom)
            Button(L("OK")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .font(.system(size: 13 * zoom))
                .padding(.top, 2 * zoom)
        }
        .padding(.horizontal, 28 * zoom)
        .padding(.vertical, 22 * zoom)
        .frame(width: 380 * zoom)
    }
}
