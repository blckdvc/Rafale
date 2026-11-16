import AppKit
import Foundation

/// Montage et démontage des images disque, sans fenêtre du Finder.
enum DiskImage {
    private static var mounted = Set<String>()
    private static let lock = NSLock()

    struct Info {
        var encrypted = false
        var license = false
    }

    static func info(_ url: URL) -> Info? {
        let r = Shell.run("/usr/bin/hdiutil", ["imageinfo", "-plist", url.path])
        guard r.ok, let d = plist(r.out) else { return nil }
        let props = d["Properties"] as? [String: Any] ?? [:]
        return Info(encrypted: props["Encrypted"] as? Bool ?? false,
                    license: props["Software License Agreement"] as? Bool ?? false)
    }

    /// Monte l'image en lecture seule dans un dossier temporaire et rend ses points de montage.
    static func attach(_ url: URL, license: Bool) -> [URL] {
        let r = Shell.run("/usr/bin/hdiutil",
                          ["attach", "-plist", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                           "-mountrandom", NSTemporaryDirectory(), url.path],
                          stdin: license ? "Y\n" : nil, env: ["PAGER": "/bin/cat"])
        guard r.ok, let d = plist(r.out) else { return [] }
        let entities = d["system-entities"] as? [[String: Any]] ?? []
        let points = entities.compactMap { $0["mount-point"] as? String }
        lock.lock(); points.forEach { mounted.insert($0) }; lock.unlock()
        return points.map { URL(fileURLWithPath: $0) }
    }

    static func detach(_ mountPoint: URL) {
        if !Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path]).ok {
            Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }
        lock.lock(); mounted.remove(mountPoint.path); lock.unlock()
    }

    static func detachAll() {
        lock.lock(); let all = mounted; lock.unlock()
        all.forEach { detach(URL(fileURLWithPath: $0)) }
    }

    /// Le texte de la licence peut précéder le plist : on ne garde que celui-ci.
    private static func plist(_ text: String) -> [String: Any]? {
        guard let start = text.range(of: "<?xml") else { return nil }
        let data = Data(text[start.lowerBound...].utf8)
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// Donne accès au contenu d'un élément de la file le temps d'une opération.
struct Container {
    let root: URL
    private let mountPoints: [URL]

    static func open(_ item: QueueItem) -> Container? {
        switch item.kind {
        case .pkg:
            return Container(root: item.url.deletingLastPathComponent(), mountPoints: [])
        case .zip:
            guard let dir = item.workDir else { return nil }
            return Container(root: dir, mountPoints: [])
        case .dmg:
            let points = DiskImage.attach(item.url, license: item.hasLicense)
            guard let first = points.first else { return nil }
            return Container(root: first, mountPoints: points)
        }
    }

    func close() { mountPoints.forEach(DiskImage.detach) }
}

enum Analyzer {
    struct Result {
        var payloads: [Payload] = []
        var notes: [String] = []
        var state: ItemState = .ready
        var workDir: URL?
        var hasLicense = false
    }

    static func analyze(url: URL, kind: SourceKind) -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Result(state: .unsupported(L("Fichier introuvable")))
        }
        switch kind {
        case .pkg:
            return Result(payloads: [inspectPkg(url, relative: url.lastPathComponent)])
        case .dmg:
            return analyzeDMG(url)
        case .zip:
            return analyzeZIP(url)
        }
    }

    // MARK: Images disque

    private static func analyzeDMG(_ url: URL) -> Result {
        var r = Result()
        guard let info = DiskImage.info(url) else {
            r.state = .unsupported(L("Image disque illisible"))
            return r
        }
        if info.encrypted {
            r.state = .unsupported(L("Image chiffrée : mot de passe requis"))
            return r
        }
        r.hasLicense = info.license
        if info.license { r.notes.append(L("Licence de l'image acceptée automatiquement au montage.")) }
        let points = DiskImage.attach(url, license: info.license)
        guard let root = points.first else {
            r.state = .unsupported(L("Montage impossible"))
            return r
        }
        scan(root: root, into: &r)
        points.forEach(DiskImage.detach)
        return r
    }

    // MARK: Archives

    private static func analyzeZIP(_ url: URL) -> Result {
        var r = Result()
        // Coup d'œil à la table de l'archive avant de l'extraire pour rien.
        let listing = Shell.run("/usr/bin/zipinfo", ["-1", url.path]).out
        let wanted = listing.split(separator: "\n").contains { line in
            let parts = line.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.first != "__MACOSX" else { return false }
            return parts.prefix(2).contains { p in
                let l = p.lowercased()
                return l.hasSuffix(".app") || l.hasSuffix(".pkg") || l.hasSuffix(".mpkg")
            }
        }
        guard wanted else {
            r.state = .unsupported(L("Rien d'installable dans l'archive"))
            return r
        }
        let dir = Scratch.make("zip")
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path]).ok else {
            try? FileManager.default.removeItem(at: dir)
            r.state = .unsupported(L("Archive illisible"))
            return r
        }
        r.workDir = dir
        scan(root: dir, into: &r)
        return r
    }

    // MARK: Contenu d'un conteneur

    private static func visible(_ dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return all.filter { $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func scan(root: URL, into r: inout Result) {
        var dir = root
        var prefix = ""
        var entries = visible(dir)
        // Archive dont tout le contenu est rangé dans un seul dossier.
        if entries.count == 1, let only = entries.first,
           !["app", "pkg", "mpkg"].contains(only.pathExtension.lowercased()),
           (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            dir = only
            prefix = only.lastPathComponent + "/"
            entries = visible(dir)
        }

        func isUninstaller(_ u: URL) -> Bool {
            let l = u.lastPathComponent.lowercased()
            return l.contains("uninstall") || l.contains("désinstall") || l.contains("desinstall")
        }
        func isInstallerApp(_ u: URL) -> Bool {
            let l = u.lastPathComponent.lowercased()
            return l.contains("install") || l.contains("setup")
        }

        let apps = entries.filter { $0.pathExtension.lowercased() == "app" && !isUninstaller($0) }
        let realApps = apps.filter { !isInstallerApp($0) }
        let pkgs = entries.filter { ["pkg", "mpkg"].contains($0.pathExtension.lowercased()) && !isUninstaller($0) }

        if !realApps.isEmpty {
            r.payloads = realApps.map { inspectApp($0, relative: prefix + $0.lastPathComponent) }
        } else if !pkgs.isEmpty {
            r.payloads = pkgs.map { inspectPkg($0, relative: prefix + $0.lastPathComponent) }
        } else if let installer = apps.first {
            r.state = .manual(L("Installeur interactif : ouvert à la fin du lot"))
            r.notes.append(L("Contient « %@ », à lancer à la main.", installer.lastPathComponent))
        } else {
            r.state = .unsupported(L("Rien d'installable trouvé"))
        }
    }

    // MARK: Apps

    static func inspectApp(_ url: URL, relative: String) -> Payload {
        let name = url.deletingPathExtension().lastPathComponent
        var p = Payload(kind: .app, relativePath: relative, name: name)
        p.destination = "/Applications/" + url.lastPathComponent
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        p.identifier = info?["CFBundleIdentifier"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        p.version = info?["CFBundleShortVersionString"] as? String ?? build

        let du = Shell.run("/usr/bin/du", ["-sk", url.path]).out
        p.sizeBytes = (Int64(du.split(separator: "\t").first ?? "") ?? 0) * 1024
        (p.trust, p.trustDetail) = assess(url, type: "execute")

        // Version déjà en place : d'abord à la destination, sinon là où macOS connaît l'app.
        var installed = URL(fileURLWithPath: p.destination)
        if !FileManager.default.fileExists(atPath: installed.path), !p.identifier.isEmpty,
           let known = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.identifier),
           known.path.hasPrefix("/Applications/") || known.path.hasPrefix(NSHomeDirectory() + "/Applications/") {
            installed = known
        }
        if let cur = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")) {
            let curBuild = cur["CFBundleVersion"] as? String ?? ""
            let curVersion = cur["CFBundleShortVersionString"] as? String ?? curBuild
            p.installedVersion = curVersion
            var order = compareVersions(p.version, curVersion)
            if order == .orderedSame { order = compareVersions(build, curBuild) }
            p.comparison = order == .orderedDescending ? .update : order == .orderedSame ? .same : .older
        } else {
            p.comparison = .new
        }
        return p
    }

    // MARK: Paquets

    static func inspectPkg(_ url: URL, relative: String) -> Payload {
        let fallbackName = url.deletingPathExtension().lastPathComponent
        var p = Payload(kind: .pkg, relativePath: relative, name: fallbackName)
        (p.trust, p.trustDetail) = assess(url, type: "install")

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            // Ancien paquet en dossier : installable, mais sans métadonnées exploitables.
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            p.identifier = info?["CFBundleIdentifier"] as? String ?? ""
            p.version = info?["CFBundleShortVersionString"] as? String ?? ""
            return p
        }

        let toc = Shell.run("/usr/bin/xar", ["-tf", url.path]).out.split(separator: "\n").map(String.init)
        let wanted = toc.filter { $0 == "Distribution" || $0 == "PackageInfo" || $0.hasSuffix("/PackageInfo") }
        p.hasScripts = toc.contains { $0 == "Scripts" || $0.hasSuffix("/Scripts") }
        guard !wanted.isEmpty else { return p }
        let dir = Scratch.make("pkg")
        defer { try? FileManager.default.removeItem(at: dir) }
        Shell.run("/usr/bin/xar", ["-xf", url.path, "-C", dir.path] + wanted)

        var distVersion = ""
        var distRefs: [PkgRef] = []
        if let doc = try? XMLDocument(contentsOf: dir.appendingPathComponent("Distribution")),
           let root = doc.rootElement() {
            if let title = root.elements(forName: "title").first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty, title.range(of: "^[A-Z0-9_.-]+$", options: .regularExpression) == nil {
                p.name = title
            }
            if let product = root.elements(forName: "product").first {
                distVersion = product.attribute(forName: "version")?.stringValue ?? ""
                p.identifier = product.attribute(forName: "id")?.stringValue ?? ""
            }
            for ref in root.elements(forName: "pkg-ref") {
                guard let id = ref.attribute(forName: "id")?.stringValue,
                      let v = ref.attribute(forName: "version")?.stringValue, !v.isEmpty else { continue }
                if !distRefs.contains(where: { $0.id == id }) { distRefs.append(PkgRef(id: id, version: v)) }
            }
        }

        var refs: [PkgRef] = []
        // Bundle principal déclaré par le paquet : sa version parle plus que celle du paquet,
        // souvent laissée à « 1.0 » par l'éditeur.
        var mainBundle: (version: String, build: String, path: String, isApp: Bool)?
        for name in wanted where name.hasSuffix("PackageInfo") {
            guard let doc = try? XMLDocument(contentsOf: dir.appendingPathComponent(name)),
                  let root = doc.rootElement(),
                  let id = root.attribute(forName: "identifier")?.stringValue else { continue }
            refs.append(PkgRef(id: id, version: root.attribute(forName: "version")?.stringValue ?? ""))
            let location = root.attribute(forName: "install-location")?.stringValue ?? "/"
            for node in (try? root.nodes(forXPath: ".//bundle[@CFBundleShortVersionString]")) ?? [] {
                guard let b = node as? XMLElement, (b.parent as? XMLElement)?.name != "bundle",
                      let rel = b.attribute(forName: "path")?.stringValue,
                      let v = b.attribute(forName: "CFBundleShortVersionString")?.stringValue else { continue }
                let isApp = rel.hasSuffix(".app")
                if mainBundle == nil || (isApp && mainBundle?.isApp == false) {
                    let full = (location as NSString).appendingPathComponent(String(rel.dropFirst(rel.hasPrefix("./") ? 2 : 0)))
                    mainBundle = (v, b.attribute(forName: "CFBundleVersion")?.stringValue ?? "", full, isApp)
                }
            }
            if let payload = root.elements(forName: "payload").first,
               let kb = Int64(payload.attribute(forName: "installKBytes")?.stringValue ?? "") {
                p.sizeBytes += kb * 1024
            }
        }
        if refs.isEmpty { refs = distRefs }

        for i in refs.indices { refs[i].installed = installedPkgVersion(refs[i].id) }
        p.packages = refs
        if p.identifier.isEmpty { p.identifier = refs.first?.id ?? "" }
        p.version = distVersion.isEmpty ? (refs.first?.version ?? "") : distVersion
        p.installedVersion = refs.compactMap(\.installed).first

        let known = refs.filter { $0.installed != nil }
        if refs.isEmpty {
            p.comparison = .unknown
        } else if known.isEmpty {
            p.comparison = .new
        } else {
            let orders = known.map { compareVersions($0.version, $0.installed ?? "") }
            if orders.contains(.orderedDescending) || known.count < refs.count {
                p.comparison = .update
            } else if orders.allSatisfy({ $0 == .orderedSame }) {
                p.comparison = .same
            } else {
                p.comparison = .older
            }
        }

        if let b = mainBundle {
            p.version = b.version
            if let cur = NSDictionary(contentsOfFile: b.path + "/Contents/Info.plist") {
                let curBuild = cur["CFBundleVersion"] as? String ?? ""
                let curVersion = cur["CFBundleShortVersionString"] as? String ?? curBuild
                p.installedVersion = curVersion
                var order = compareVersions(b.version, curVersion)
                if order == .orderedSame { order = compareVersions(b.build, curBuild) }
                p.comparison = order == .orderedDescending ? .update : order == .orderedSame ? .same : .older
            } else if known.isEmpty {
                p.comparison = .new
            }
        }
        return p
    }

    private static func installedPkgVersion(_ id: String) -> String? {
        let r = Shell.run("/usr/sbin/pkgutil", ["--pkg-info-plist", id])
        guard r.ok, let d = try? PropertyListSerialization.propertyList(from: Data(r.out.utf8), format: nil),
              let dict = d as? [String: Any] else { return nil }
        return dict["pkg-version"] as? String
    }

    // MARK: Signature

    /// Lit le verdict de Gatekeeper. La ligne « source » reste fiable même quand les
    /// vérifications sont désactivées sur la machine, alors que le code de retour ne l'est plus.
    static func assess(_ url: URL, type: String) -> (Trust, String) {
        let r = Shell.run("/usr/sbin/spctl", ["--assess", "--type", type, "-vv", url.path])
        var source = "", origin = ""
        for line in r.all.split(separator: "\n") {
            if line.hasPrefix("source=") { source = String(line.dropFirst(7)) }
            if line.hasPrefix("origin=") { origin = String(line.dropFirst(7)) }
        }
        for prefix in ["Developer ID Application: ", "Developer ID Installer: "] where origin.hasPrefix(prefix) {
            origin = String(origin.dropFirst(prefix.count))
        }
        let detail = origin.isEmpty ? source : origin
        let s = source.lowercased()
        if s.contains("unnotarized") { return (.unnotarized, detail) }
        if s.contains("notarized") { return (.notarized, detail) }
        if s.contains("no usable signature") || s.contains("unsigned") { return (.unsigned, "") }
        if s.contains("apple system") || s.contains("mac app store") || s.contains("developer id") {
            return (.signed, detail)
        }
        if source.isEmpty { return type == "install" ? pkgSignature(url) : appSignature(url) }
        return (r.ok ? .signed : .rejected, detail)
    }

    /// Quand Gatekeeper ne dit rien de la provenance, on lit la signature elle-même.
    private static func appSignature(_ url: URL) -> (Trust, String) {
        let text = Shell.run("/usr/bin/codesign", ["-dvv", url.path]).all
        if text.contains("Signature=adhoc") { return (.unsigned, L("Signature locale (ad hoc)")) }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") }) else {
            return (.unsigned, "")
        }
        let authority = String(line.dropFirst(10))
        if authority.hasPrefix("Developer ID Application: ") {
            let name = String(authority.dropFirst(26))
            let notarized = Shell.run("/usr/bin/codesign", ["--verify", "-R=notarized", url.path]).ok
            return (notarized ? .notarized : .unnotarized, name)
        }
        if authority.hasPrefix("Apple ") || authority == "Software Signing" { return (.signed, authority) }
        return (.unsigned, authority)
    }

    private static func pkgSignature(_ url: URL) -> (Trust, String) {
        let text = Shell.run("/usr/sbin/pkgutil", ["--check-signature", url.path]).all
        if text.contains("no signature") { return (.unsigned, "") }
        var name = ""
        if let line = text.split(separator: "\n").first(where: { $0.contains("1. ") }),
           let r = line.range(of: "1. ") {
            name = String(line[r.upperBound...]).replacingOccurrences(of: "Developer ID Installer: ", with: "")
        }
        if text.contains("trusted by the Apple notary service") { return (.notarized, name) }
        if text.contains("issued by Apple") { return (.unnotarized, name) }
        return (.unknown, name)
    }

    // MARK: Scripts d'un paquet

    /// Texte des scripts exécutés en root par un paquet, pour les lire avant d'installer.
    static func scripts(of pkg: URL) -> String {
        let toc = Shell.run("/usr/bin/xar", ["-tf", pkg.path]).out.split(separator: "\n").map(String.init)
        let wanted = toc.filter { $0 == "Scripts" || $0.hasSuffix("/Scripts") }
        guard !wanted.isEmpty else { return L("Ce paquet n'exécute aucun script.") }
        let dir = Scratch.make("scripts")
        defer { try? FileManager.default.removeItem(at: dir) }
        Shell.run("/usr/bin/xar", ["-xf", pkg.path, "-C", dir.path] + wanted)

        var text = ""
        for name in wanted {
            let archive = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: archive.path, isDirectory: &isDir)
            var folder = archive
            if !isDir.boolValue {
                folder = Scratch.make("cpio")
                Shell.run("/bin/sh", ["-c",
                    "cd \"$1\" && (/usr/bin/gunzip -c \"$2\" 2>/dev/null || /bin/cat \"$2\") | /usr/bin/cpio -i 2>/dev/null",
                    "sh", folder.path, archive.path])
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let main = files.filter { ["preinstall", "postinstall"].contains($0.lastPathComponent) }
            let others = files.filter { !main.contains($0) }.map(\.lastPathComponent).sorted()
            let owner = name == "Scripts" ? "" : String(name.dropLast("/Scripts".count)) + " — "
            for f in main.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                text += "━━━ \(owner)\(f.lastPathComponent) ━━━\n"
                if let data = try? Data(contentsOf: f), let s = String(data: data.prefix(200_000), encoding: .utf8) {
                    text += s + "\n\n"
                } else {
                    text += L("(fichier binaire)") + "\n\n"
                }
            }
            if !others.isEmpty {
                text += "━━━ \(owner)" + L("autres fichiers") + " ━━━\n" + others.joined(separator: "\n") + "\n\n"
            }
            if folder != archive { try? FileManager.default.removeItem(at: folder) }
        }
        return text.isEmpty ? L("Ce paquet n'exécute aucun script.") : text
    }
}
