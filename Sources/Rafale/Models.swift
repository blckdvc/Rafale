import AppKit
import Foundation
import UniformTypeIdentifiers

enum SourceKind: String {
    case pkg, dmg, zip

    static func of(_ url: URL) -> SourceKind? {
        switch url.pathExtension.lowercased() {
        case "pkg", "mpkg": return .pkg
        case "dmg": return .dmg
        case "zip": return .zip
        default: return nil
        }
    }
}

enum Comparison: Int {
    case new, update, same, older, unknown
}

enum Trust: Int {
    case notarized, signed, unnotarized, unsigned, rejected, unknown

    /// Ce que Gatekeeper laisserait passer.
    var ok: Bool { self == .notarized || self == .signed }

    var label: String {
        switch self {
        case .notarized: return L("Notarisé")
        case .signed: return L("Signé")
        case .unnotarized: return L("Non notarisé")
        case .unsigned: return L("Non signé")
        case .rejected: return L("Refusé")
        case .unknown: return L("Inconnu")
        }
    }
}

struct PkgRef: Hashable {
    var id: String
    var version: String
    var installed: String?
}

/// Ce qu'un fichier de la file installe réellement : une app à copier ou un paquet.
struct Payload: Identifiable {
    enum Kind { case app, pkg }
    let id = UUID()
    var kind: Kind
    /// Chemin relatif à la racine du conteneur (image montée, archive extraite, dossier du pkg).
    var relativePath: String
    var name: String
    var identifier = ""
    var version = ""
    var installedVersion: String?
    var comparison: Comparison = .unknown
    var trust: Trust = .unknown
    var trustDetail = ""
    var sizeBytes: Int64 = 0
    var hasScripts = false
    var packages: [PkgRef] = []
    var destination = "/"
}

enum ItemState: Equatable {
    case analyzing
    case ready
    case manual(String)
    case unsupported(String)
    case waiting
    /// Avancement de 0 à 100, ou -1 quand il n'est pas mesurable.
    case running(Double, String)
    case done
    case failed(String)
    case skipped

    var rank: Int {
        switch self {
        case .running: return 0
        case .waiting: return 1
        case .analyzing: return 2
        case .failed: return 3
        case .ready: return 4
        case .manual: return 5
        case .skipped: return 6
        case .done: return 7
        case .unsupported: return 8
        }
    }
}

final class QueueItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let kind: SourceKind
    var fileSize: Int64
    /// Icône du fichier, ou celle de son type quand le fichier n'est pas sur le disque.
    lazy var icon: NSImage = {
        if FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }()

    @Published var enabled = false
    @Published var state: ItemState = .analyzing
    @Published var payloads: [Payload] = []
    @Published var notes: [String] = []
    @Published var log = ""
    var hasLicense = false
    /// Archive zip déjà extraite pendant l'analyse.
    var workDir: URL?

    init(url: URL, kind: SourceKind) {
        self.url = url
        self.kind = kind
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        fileSize = Int64(v?.fileSize ?? 0)
    }

    var displayName: String {
        guard let first = payloads.first else { return url.deletingPathExtension().lastPathComponent }
        return payloads.count > 1 ? "\(first.name) +\(payloads.count - 1)" : first.name
    }

    var version: String { payloads.first?.version ?? "" }

    var comparison: Comparison {
        let all = payloads.map(\.comparison)
        if all.isEmpty { return .unknown }
        if all.contains(.update) { return .update }
        if all.contains(.new) { return .new }
        if all.contains(.older) { return .older }
        if all.allSatisfy({ $0 == .same }) { return .same }
        return .unknown
    }

    var installedVersion: String? { payloads.compactMap(\.installedVersion).first }

    var trust: Trust {
        payloads.map(\.trust).max { $0.rawValue < $1.rawValue } ?? .unknown
    }

    var installSize: Int64 { payloads.reduce(0) { $0 + $1.sizeBytes } }

    var typeLabel: String {
        let src = kind.rawValue.uppercased()
        if case .manual = state { return kind == .pkg ? src : "\(src) → " + L("installeur") }
        guard let p = payloads.first else { return src }
        if kind == .pkg { return "PKG" }
        return "\(src) → " + (p.kind == .app ? "App" : "PKG")
    }

    var isManual: Bool { if case .manual = state { return true }; return false }

    /// Peut partir dans le prochain lot.
    var isInstallable: Bool {
        switch state {
        case .ready, .failed, .skipped: return !payloads.isEmpty
        default: return false
        }
    }

    var canToggle: Bool {
        switch state {
        case .analyzing, .unsupported, .waiting, .running, .done: return false
        default: return true
        }
    }
}

struct SavedList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var paths: [String]
}

func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    a.compare(b, options: .numeric)
}
