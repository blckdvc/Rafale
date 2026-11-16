import AppKit
import Foundation

/// Exécute un lot : copie les apps avec les droits de l'utilisateur, puis regroupe tout ce
/// qui exige root (paquets, apps protégées) dans un seul script, donc une seule demande de
/// mot de passe pour tout le lot.
@MainActor
final class BatchRunner {
    struct Outcome {
        var done = 0
        var failed = 0
        var skipped = 0
    }

    private struct RootStep {
        let item: QueueItem
        let payloadID: UUID
        let label: String
        let command: String
    }

    private enum CopyResult {
        case ok
        case needsRoot
        case error(String)
    }

    private let stopFlag = Scratch.base.appendingPathComponent("stop-\(UUID().uuidString.prefix(8))")
    private(set) var stopping = false

    /// Laisse l'opération en cours se terminer, puis n'en lance plus d'autre.
    func stop() {
        stopping = true
        FileManager.default.createFile(atPath: stopFlag.path, contents: nil)
    }

    private func bg<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
        }
    }

    func run(_ items: [QueueItem], manual: [QueueItem], quitRunningApps: Bool, trashSources: Bool) async -> Outcome {
        var containers: [UUID: Container] = [:]
        var steps: [RootStep] = []
        items.forEach { $0.state = .waiting; $0.log = "" }

        for item in items {
            if stopping { item.state = .skipped; continue }
            item.state = .running(-1, L("Ouverture…"))
            guard let c = await bg({ Container.open(item) }) else {
                item.state = .failed(L("Impossible d'ouvrir le fichier"))
                continue
            }
            containers[item.id] = c
            var failure: String?
            var needsRoot = false

            for p in item.payloads where failure == nil {
                let src = c.root.appendingPathComponent(p.relativePath)
                switch p.kind {
                case .pkg:
                    let untrusted = p.trust.ok ? "" : "-allowUntrusted "
                    steps.append(RootStep(item: item, payloadID: p.id, label: p.name, command:
                        "/usr/sbin/installer -verboseR \(untrusted)-pkg \(shellQuote(src.path)) -target /"))
                    needsRoot = true
                case .app:
                    if !p.identifier.isEmpty, !(await quit(p.identifier, allowed: quitRunningApps)) {
                        failure = L("App ouverte : quittez-la puis relancez")
                        break
                    }
                    item.state = .running(-1, L("Copie de %@…", p.name))
                    let dest = URL(fileURLWithPath: p.destination)
                    switch await bg({ Self.copyApp(src, to: dest) }) {
                    case .ok:
                        item.log += L("Copié dans %@", p.destination) + "\n"
                    case .needsRoot:
                        let tmp = Self.staging(for: dest).path
                        steps.append(RootStep(item: item, payloadID: p.id, label: p.name, command:
                            "/usr/bin/ditto \(shellQuote(src.path)) \(shellQuote(tmp)) && /bin/rm -rf \(shellQuote(dest.path))"
                            + " && /bin/mv \(shellQuote(tmp)) \(shellQuote(dest.path))"
                            + " && /usr/sbin/chown -R \(getuid()):\(getgid()) \(shellQuote(dest.path))"))
                        needsRoot = true
                    case .error(let message):
                        failure = message
                    }
                }
            }

            if let failure {
                steps.removeAll { $0.item === item }
                item.state = .failed(failure)
            } else {
                item.state = needsRoot ? .waiting : .done
            }
        }

        if !steps.isEmpty {
            if stopping {
                steps.forEach { $0.item.state = .skipped }
            } else {
                await runAsRoot(steps)
            }
        }

        let all = Array(containers.values)
        await bg { all.forEach { $0.close() } }

        var outcome = Outcome()
        for item in items {
            switch item.state {
            case .done:
                outcome.done += 1
                for i in item.payloads.indices {
                    item.payloads[i].installedVersion = item.payloads[i].version
                    item.payloads[i].comparison = .same
                }
                if trashSources { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
            case .failed:
                outcome.failed += 1
            default:
                item.state = .skipped
                outcome.skipped += 1
            }
        }
        // Les installeurs interactifs ne s'automatisent pas : on les ouvre, à l'utilisateur de jouer.
        if !stopping { manual.forEach { NSWorkspace.shared.open($0.url) } }
        try? FileManager.default.removeItem(at: stopFlag)
        return outcome
    }

    // MARK: Apps en cours d'exécution

    private func quit(_ bundleID: String, allowed: Bool) async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return true }
        guard allowed else { return false }
        running.forEach { $0.terminate() }
        for _ in 0..<40 {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return running.allSatisfy(\.isTerminated)
    }

    // MARK: Copie d'une app

    nonisolated private static func staging(for dest: URL) -> URL {
        dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".rafale")
    }

    /// Copie à côté de la destination puis bascule, pour ne jamais laisser une app à moitié écrite.
    nonisolated private static func copyApp(_ src: URL, to dest: URL) -> CopyResult {
        let fm = FileManager.default
        let tmp = staging(for: dest)
        try? fm.removeItem(at: tmp)
        let r = Shell.run("/usr/bin/ditto", [src.path, tmp.path])
        guard r.ok else {
            try? fm.removeItem(at: tmp)
            if !fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) { return .needsRoot }
            return .error(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if fm.fileExists(atPath: dest.path) {
            do { try fm.removeItem(at: dest) } catch {
                try? fm.removeItem(at: tmp)
                return .needsRoot
            }
        }
        do { try fm.moveItem(at: tmp, to: dest) } catch {
            try? fm.removeItem(at: tmp)
            return .error(error.localizedDescription)
        }
        return .ok
    }

    // MARK: Étapes root

    private func runAsRoot(_ steps: [RootStep]) async {
        let dir = Scratch.make("batch")
        let log = dir.appendingPathComponent("log.txt")
        let script = dir.appendingPathComponent("batch.sh")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        var sh = "#!/bin/sh\nLOG=\(shellQuote(log.path))\nSTOP=\(shellQuote(stopFlag.path))\n"
        for (i, step) in steps.enumerated() {
            sh += """
            if [ -e "$STOP" ]; then echo "@@END \(i) 130" >> "$LOG"; else
            echo "@@BEGIN \(i)" >> "$LOG"
            ( \(step.command) ) >> "$LOG" 2>&1
            echo "@@END \(i) $?" >> "$LOG"
            fi

            """
        }
        try? sh.write(to: script, atomically: true, encoding: .utf8)

        let prompt = L("Rafale installe %d élément(s) qui demandent les droits administrateur.", steps.count)
        let source = "do shell script \"/bin/sh \(shellQuote(script.path))\" with prompt \""
            + prompt.replacingOccurrences(of: "\"", with: "'") + "\" with administrator privileges"

        var remaining: [ObjectIdentifier: Int] = [:]
        var failures: [ObjectIdentifier: String] = [:]
        var skipped = Set<ObjectIdentifier>()
        steps.forEach { remaining[ObjectIdentifier($0.item), default: 0] += 1 }

        var finished = false
        var result = ShellResult(status: -1, out: "", err: "")
        Task.detached {
            let r = Shell.run("/usr/bin/osascript", ["-e", source])
            await MainActor.run { result = r; finished = true }
        }

        var offset: UInt64 = 0
        var partial = ""
        var current: Int?
        var lastLine = ""

        func consume() {
            guard let h = try? FileHandle(forReadingFrom: log) else { return }
            defer { try? h.close() }
            try? h.seek(toOffset: offset)
            let data = h.readDataToEndOfFile()
            guard !data.isEmpty else { return }
            offset += UInt64(data.count)
            partial += String(decoding: data, as: UTF8.self)
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()

            for line in lines {
                if line.hasPrefix("@@BEGIN ") {
                    current = Int(line.dropFirst(8))
                    lastLine = ""
                    if let i = current { steps[i].item.state = .running(0, steps[i].label) }
                } else if line.hasPrefix("@@END ") {
                    let parts = line.split(separator: " ")
                    guard parts.count == 3, let i = Int(parts[1]), let code = Int(parts[2]) else { continue }
                    let key = ObjectIdentifier(steps[i].item)
                    if code == 130 {
                        skipped.insert(key)
                    } else if code != 0 {
                        failures[key] = lastLine.isEmpty ? L("Échec (code %d)", code) : lastLine
                    }
                    remaining[key, default: 1] -= 1
                    if remaining[key] == 0 {
                        if let f = failures[key] { steps[i].item.state = .failed(f) }
                        else if skipped.contains(key) { steps[i].item.state = .skipped }
                        else { steps[i].item.state = .done }
                    }
                    current = nil
                } else if let i = current {
                    let item = steps[i].item
                    if line.hasPrefix("installer:%") {
                        let pct = Double(line.dropFirst(11)) ?? 0
                        if case .running(_, let phase) = item.state { item.state = .running(pct, phase) }
                    } else if line.hasPrefix("installer:PHASE:") {
                        let phase = String(line.dropFirst(16))
                        if case .running(let pct, _) = item.state, !phase.isEmpty { item.state = .running(pct, phase) }
                    } else if line.hasPrefix("installer:STATUS:") {
                        continue
                    } else if !line.isEmpty {
                        let clean = line.hasPrefix("installer: ") ? String(line.dropFirst(11)) : line
                        lastLine = clean
                        item.log += clean + "\n"
                    }
                }
            }
        }

        while !finished {
            consume()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        consume()

        // Ce qui n'a jamais reçu de fin : mot de passe refusé ou script interrompu.
        let refused = result.all.contains("-128")
        for step in steps where (remaining[ObjectIdentifier(step.item)] ?? 0) > 0 {
            step.item.state = refused ? .skipped : .failed(
                result.ok ? L("Interrompu") : result.err.trimmingCharacters(in: .whitespacesAndNewlines))
            if refused { step.item.log += L("Autorisation administrateur refusée.") + "\n" }
        }
        try? FileManager.default.removeItem(at: dir)
    }
}
