import Foundation

/// Jeu de données inventé, pour les captures d'écran du README : lancer l'app avec
/// `-demoData YES` remplace la file réelle par celle-ci. `-demoStage` choisit l'état montré :
/// `analyzed` (par défaut), `running`, `done` ou `empty`. `-demoSelect script` sélectionne un
/// élément qui porte un script de post-installation, `-demoSelect group` l'en-tête d'un groupe.
/// Aucun de ces éditeurs ni de ces fichiers n'existe ; rien n'est lu, installé ni enregistré.
enum DemoData {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demoData") }
    static var stage: String { UserDefaults.standard.string(forKey: "demoStage") ?? "analyzed" }

    static let lists = [
        SavedList(name: "Fresh install", paths: Array(repeating: "", count: 9)),
        SavedList(name: "Audio workstation", paths: Array(repeating: "", count: 14)),
    ]

    static let script = """
    ━━━ postinstall ━━━
    #!/bin/sh
    # Registers the backup daemon and starts it.
    PLIST="/Library/LaunchDaemons/com.larkspur.backup.daemon.plist"
    /bin/launchctl bootout system "$PLIST" 2>/dev/null || true
    /bin/launchctl bootstrap system "$PLIST"
    /usr/sbin/chown -R root:wheel "/Library/Application Support/Larkspur"
    exit 0

    ━━━ preinstall ━━━
    #!/bin/sh
    # Stops the previous version before its files are replaced.
    /usr/bin/pkill -x backupd 2>/dev/null || true
    exit 0

    """

    static let postScript = """
    #!/bin/bash
    # Runs once Finchley Clipboard is installed: sets it up for this Mac.
    set -euo pipefail

    echo "Configuring $RAFALE_APP for $RAFALE_USER"
    defaults write com.finchley.clipboard HistorySize -int "$2"
    defaults write com.finchley.clipboard LaunchAtLogin -bool true
    echo "Done."

    """

    static let userScripts: Set<String> = [folder + "setup.sh"]
    static let scriptArgs = [folder + "setup.sh": "--history 200 --launch-at-login",
                             groupScript: "--team studio"]
    private static let groupScript = folder + "Wrenfield/register-agent.sh"

    static var selectedGroup: URL? {
        UserDefaults.standard.string(forKey: "demoSelect") == "group" && stage != "empty" ? URL(fileURLWithPath: groupScript) : nil
    }

    private static let folder = "/Users/demo/Downloads/Installers/"

    private static func item(_ file: String, _ kind: SourceKind, mb: Double, _ payload: Payload,
                             enabled: Bool = true, state: ItemState = .ready,
                             notes: [String] = [], log: String = "") -> QueueItem {
        let q = QueueItem(url: URL(fileURLWithPath: folder + file), kind: kind)
        q.fileSize = Int64(mb * 1_000_000)
        q.payloads = state == .manual("") ? [] : [payload]
        q.enabled = enabled
        q.state = state
        q.notes = notes
        q.log = log
        return q
    }

    private static func app(_ name: String, _ id: String, _ version: String, mb: Double, team: String,
                            installed: String? = nil, _ comparison: Comparison = .new,
                            trust: Trust = .notarized) -> Payload {
        var p = Payload(kind: .app, relativePath: name + ".app", name: name)
        p.identifier = id
        p.version = version
        p.installedVersion = installed
        p.comparison = comparison
        p.trust = trust
        p.trustDetail = trust.ok ? team : ""
        p.sizeBytes = Int64(mb * 1_000_000)
        p.destination = "/Applications/\(name).app"
        return p
    }

    private static func pkg(_ name: String, _ id: String, _ version: String, mb: Double, team: String,
                            installed: String? = nil, _ comparison: Comparison = .new,
                            components: [String] = []) -> Payload {
        var p = Payload(kind: .pkg, relativePath: name + ".pkg", name: name)
        p.identifier = id
        p.version = version
        p.installedVersion = installed
        p.comparison = comparison
        p.trust = .notarized
        p.trustDetail = team
        p.sizeBytes = Int64(mb * 1_000_000)
        p.hasScripts = true
        p.packages = ([id] + components).map { PkgRef(id: $0, version: version, installed: installed) }
        return p
    }

    /// La file, dans l'état demandé. Le second élément rendu est celui à sélectionner.
    static func queue() -> (items: [QueueItem], selected: QueueItem?) {
        guard stage != "empty" else { return ([], nil) }
        let running = stage == "running", done = stage == "done"

        let notes = item("Wrenfield/Wrenfield Notes 2.3.dmg", .dmg, mb: 48.2,
                         app("Wrenfield Notes", "com.wrenfield.notes", "2.3", mb: 131, team: "Wrenfield Software Ltd (W4R9NF13LD)"),
                         state: running || done ? .done : .ready,
                         log: running || done ? "Copied to /Applications/Wrenfield Notes.app\n" : "")
        let backup = item("Larkspur Backup 5.1.pkg", .pkg, mb: 212.7,
                          pkg("Larkspur Backup", "com.larkspur.backup", "5.1", mb: 486, team: "Larkspur Labs GmbH (L8K5PR2BKP)",
                              installed: "4.8", .update,
                              components: ["com.larkspur.backup.daemon", "com.larkspur.backup.menu"]),
                          state: running ? .running(62, "Writing files…") : done ? .done : .ready,
                          log: done ? "The upgrade was successful.\n" : "")
        let vpn = item("Bluefinch VPN 3.2.1.dmg", .dmg, mb: 37.9,
                       pkg("Bluefinch VPN", "net.bluefinch.vpn", "3.2.1", mb: 92, team: "Bluefinch Networks Inc. (B3F7NCH9VP)"),
                       state: running ? .waiting : done ? .failed("The package requires macOS 28 or later.") : .ready,
                       notes: ["The image's license agreement is accepted automatically on mount."],
                       log: done ? "Verifying package…\nThe package requires macOS 28 or later.\n" : "")
        let bridge = item("Tamarisk Audio Bridge 1.9.pkg", .pkg, mb: 18.4,
                          pkg("Tamarisk Audio Bridge", "io.tamarisk.audio.bridge", "1.9", mb: 41, team: "Tamarisk Audio SAS (T6M2RSK8AU)",
                              installed: "1.9", .same),
                          enabled: false)
        let clipboard = item("Finchley Clipboard 2.0.zip", .zip, mb: 9.6,
                             app("Finchley Clipboard", "com.finchley.clipboard", "2.0", mb: 22, team: "Finchley Apps (F1NC8L3YCB)"),
                             state: running ? .waiting : done ? .done : .ready)
        let pipit = item("Pipit 7.4.dmg", .dmg, mb: 76.3,
                         app("Pipit", "com.pipit.app", "7.4", mb: 188, team: "Pipit Software (P1P1T7SFTW)",
                             installed: "8.0", .older),
                         enabled: false)
        let marrow = item("Marrow Tools 0.9.dmg", .dmg, mb: 5.1,
                          app("Marrow Tools", "com.marrow.tools", "0.9", mb: 12, team: "", trust: .unsigned),
                          enabled: false)
        let sync = item("Wrenfield/Wrenfield Sync 1.8.pkg", .pkg, mb: 64.0,
                        pkg("Wrenfield Sync", "com.wrenfield.sync", "1.8", mb: 157, team: "Wrenfield Software Ltd (W4R9NF13LD)"),
                        state: running ? .waiting : done ? .done : .ready)
        let suite = item("Gadwall Suite Installer.dmg", .dmg, mb: 9.4,
                         app("", "", "", mb: 0, team: ""),
                         state: .manual(L("Installeur interactif : ouvert à la fin du lot")),
                         notes: [L("Contient « %@ », à lancer à la main.", "Install Gadwall Suite.app")])
        suite.payloads = []

        clipboard.script = URL(fileURLWithPath: folder + "setup.sh")
        clipboard.scriptState = running ? .waiting : done ? .done : .idle
        clipboard.scriptLog = done ? "Configuring /Applications/Finchley Clipboard.app for demo\nDone.\n" : ""
        // Un groupe : les deux installeurs du dossier Wrenfield partagent un script.
        for member in [notes, sync] {
            member.script = URL(fileURLWithPath: groupScript)
            member.scriptState = running ? .waiting : done ? .failed("launchctl: service already loaded") : .idle
            member.scriptLog = done ? "Registering the sync agent…\nlaunchctl: service already loaded\n" : ""
        }

        let all = [notes, backup, vpn, bridge, clipboard, pipit, marrow, sync, suite]
        if UserDefaults.standard.string(forKey: "demoSelect") == "script" { return (all, clipboard) }
        return (all, done ? vpn : backup)
    }

    static var summary: String? {
        guard stage == "done" else { return nil }
        return [L("%d installé(s)", 4), L("%d en échec", 1), L("%d script(s) exécuté(s)", 1), L("%d script(s) en échec", 1), L("%d à finir à la main", 1)].joined(separator: " · ")
    }
}
