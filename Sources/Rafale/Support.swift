import AppKit
import Foundation

// Traduction : les clés sont les textes français, en.lproj porte l'anglais.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

struct ShellResult {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
    var all: String { out + err }
}

enum Shell {
    @discardableResult
    static func run(_ tool: String, _ args: [String], stdin: String? = nil,
                    env: [String: String] = [:]) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if !env.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        }
        let o = Pipe(), e = Pipe(), i = Pipe()
        p.standardOutput = o
        p.standardError = e
        p.standardInput = stdin == nil ? FileHandle.nullDevice : i
        do { try p.run() } catch {
            return ShellResult(status: -1, out: "", err: error.localizedDescription)
        }
        if let stdin {
            i.fileHandleForWriting.write(Data(stdin.utf8))
            try? i.fileHandleForWriting.close()
        }
        var od = Data(), ed = Data()
        let g = DispatchGroup()
        DispatchQueue.global().async(group: g) { od = o.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: g) { ed = e.fileHandleForReading.readDataToEndOfFile() }
        g.wait()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus,
                           out: String(decoding: od, as: UTF8.self),
                           err: String(decoding: ed, as: UTF8.self))
    }
}

/// Dossier de travail temporaire, propre à ce lancement.
enum Scratch {
    static let base: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("Rafale-\(getpid())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return u
    }()

    static func make(_ prefix: String) -> URL {
        let u = base.appendingPathComponent(prefix + "-" + UUID().uuidString.prefix(8))
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func cleanup() {
        DiskImage.detachAll()
        try? FileManager.default.removeItem(at: base)
    }

    /// Retire les dossiers laissés par un lancement qui ne s'est pas terminé proprement.
    static func removeStale() {
        let tmp = FileManager.default.temporaryDirectory
        let old = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for u in old where u.lastPathComponent.hasPrefix("Rafale-") && u != base {
            let pid = Int32(u.lastPathComponent.dropFirst(7)) ?? 0
            if pid > 0, kill(pid, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: u)
        }
    }
}

enum Zoom {
    static let key = "zoom"
    static var value: Double {
        get { let v = UserDefaults.standard.double(forKey: key); return v == 0 ? 1 : v }
        set { UserDefaults.standard.set(min(2, max(0.7, (newValue * 10).rounded() / 10)), forKey: key) }
    }
    static func bigger() { value += 0.1 }
    static func smaller() { value -= 0.1 }
    static func reset() { value = 1 }
}

func formatBytes(_ n: Int64) -> String {
    n <= 0 ? "—" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
