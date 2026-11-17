import Foundation

/// Scripts de post-installation : repérés à côté des installeurs au moment du dépôt,
/// exécutés une fois les installations finies.
enum PostScript {
    static let extensions = ["sh", "bash", "zsh", "command", "py"]
    private static let suffixes = [".postinstall", "-postinstall", "_postinstall", " postinstall",
                                   ".post-install", "-post-install", "_post_install"]

    /// Un script se reconnaît à son extension ou, sans extension, à sa ligne « #! ».
    static func isScript(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { return extensions.contains(ext) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return h.readData(ofLength: 2) == Data("#!".utf8)
    }

    /// Commande qui lance le script : celle de sa ligne « #! » si elle existe sur ce Mac,
    /// sinon celle de son extension. Le fichier n'a donc pas besoin d'être exécutable.
    static func interpreter(for url: URL) -> [String] {
        if let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            let head = String(decoding: h.readData(ofLength: 512), as: UTF8.self)
            if head.hasPrefix("#!"),
               let line = head.dropFirst(2).split(separator: "\n", omittingEmptySubsequences: false).first {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
                if let tool = parts.first, FileManager.default.isExecutableFile(atPath: tool) { return parts }
            }
        }
        switch url.pathExtension.lowercased() {
        case "py": return ["/usr/bin/env", "python3"]
        case "zsh": return ["/bin/zsh"]
        default: return ["/bin/bash"]
        }
    }

    static func language(_ interpreter: [String]) -> String {
        var words = interpreter.map { ($0 as NSString).lastPathComponent }
        if words.first == "env" { words = Array(words.dropFirst().drop { $0.hasPrefix("-") || $0.contains("=") }) }
        let tool = (words.first ?? "").lowercased()
        if tool.hasPrefix("python") { return "Python" }
        switch tool {
        case "bash": return "Bash"
        case "zsh": return "zsh"
        case "sh", "dash": return "Shell"
        case "": return "Script"
        default: return words[0]
        }
    }

    /// Nom de l'installeur que le script désigne : « Outil 2.0.sh » ou
    /// « Outil 2.0.postinstall.py » vont avec « Outil 2.0.dmg ».
    static func pairingName(_ url: URL) -> String {
        var name = (url.pathExtension.isEmpty ? url.lastPathComponent
                                              : url.deletingPathExtension().lastPathComponent).lowercased()
        for s in suffixes where name.hasSuffix(s) { name = String(name.dropLast(s.count)); break }
        return name
    }

    static func isNamesake(_ script: URL, of installer: URL) -> Bool {
        pairingName(script) == installer.deletingPathExtension().lastPathComponent.lowercased()
    }

    /// Script qui porte le nom de l'installeur, dans le même dossier. Sert quand l'installeur
    /// est déposé seul : son dossier (Téléchargements…) peut contenir des scripts sans rapport.
    static func namesake(of installer: URL) -> URL? {
        let base = installer.deletingPathExtension()
        for suffix in [""] + suffixes {
            for ext in extensions {
                let u = URL(fileURLWithPath: base.path + suffix + "." + ext)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    /// Dans un dossier déposé : le script du dossier de l'installeur, sinon celui du dossier
    /// parent le plus proche, sans remonter au-dessus du dossier déposé. À plusieurs, celui
    /// qui porte le nom de l'installeur l'emporte, puis celui dont le nom contient « post ».
    static func pick(for installer: URL, among scripts: [String: [URL]], root: String) -> URL? {
        var dir = installer.deletingLastPathComponent()
        while dir.path.count >= root.count {
            if let list = scripts[dir.path], !list.isEmpty {
                let sorted = list.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                return sorted.first { isNamesake($0, of: installer) }
                    ?? sorted.first { $0.lastPathComponent.lowercased().contains("post") }
                    ?? sorted.first
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Ligne de shell qui exécute le script depuis son dossier, avec le contexte du lot.
    /// En root, le script reçoit aussi les variables qu'il aurait sous `sudo`.
    static func command(for script: URL, installed items: [QueueItem], arguments: [String] = [],
                        root: Bool = false) -> String {
        var env = ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                   "PYTHONUNBUFFERED=1",
                   "RAFALE_USER=" + NSUserName()]
        if root { env += ["SUDO_USER=" + NSUserName(), "SUDO_UID=\(getuid())", "SUDO_GID=\(getgid())"] }
        if let first = items.first { env.append("RAFALE_SOURCE=" + first.url.path) }
        if let app = items.flatMap(\.payloads).first(where: { $0.kind == .app }) {
            env.append("RAFALE_APP=" + app.destination)
        }
        let words = ["/usr/bin/env"] + env + interpreter(for: script) + [script.path] + arguments
        return "cd " + shellQuote(script.deletingLastPathComponent().path) + " && "
            + words.map(shellQuote).joined(separator: " ")
    }

    /// Découpe une ligne d'arguments comme le ferait un shell : espaces, guillemets simples
    /// ou doubles, barre oblique inverse. Rien n'est développé ($VAR, *, ~ restent tels quels).
    static func words(_ line: String) -> [String] {
        var out: [String] = [], current = "", quote: Character?, started = false, escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; started = true
            } else if ch == " " || ch == "\t" {
                if started || !current.isEmpty { out.append(current) }
                current = ""; started = false
            } else {
                current.append(ch)
            }
        }
        if started || !current.isEmpty { out.append(current) }
        return out
    }

    /// Texte du script, pour le lire avant de l'exécuter.
    static func source(of url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return L("Script illisible") }
        defer { try? h.close() }
        return String(data: h.readData(ofLength: 200_000), encoding: .utf8) ?? L("(fichier binaire)")
    }
}
