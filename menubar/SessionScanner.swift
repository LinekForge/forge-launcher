import Foundation
import os

private let log = OSLog(subsystem: "com.linekforge.forge-launcher", category: "Scanner")

final class SessionScanner {
    private(set) var sessions: [Session] = []
    private(set) var activeSIDs: Set<String> = []
    private(set) var sessionPIDMap: [String: Int] = [:]
    private(set) var staleSessions: [StaleSession] = []
    var hubTags: [String: String] = [:]
    var hubDescs: [String: String] = [:]
    private(set) var isScanning = false

    /// Called after core scan completes. HubExtension registers this to inject tags/descs.
    var onEnrich: (() -> Void)?

    // MARK: - Active Session Detection

    func scanActiveSessions() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = home.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        struct AliveEntry {
            let file: URL; let sid: String; let pid: Int; let startedAt: TimeInterval
        }
        var aliveEntries: [AliveEntry] = []

        for file in files where file.pathExtension == "json" {
            guard let rawData = try? Data(contentsOf: file) else { continue }
            var data = rawData
            if (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil,
               let str = String(data: rawData, encoding: .utf8),
               let end = str.firstIndex(of: "}") {
                let trimmed = String(str[str.startIndex...end])
                if let fixed = trimmed.data(using: .utf8) { data = fixed }
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let pid = obj["pid"] as? Int else { continue }
            if kill(Int32(pid), 0) == 0 {
                let startedAt = (obj["startedAt"] as? Double ?? 0) / 1000.0
                aliveEntries.append(AliveEntry(file: file, sid: sid, pid: pid, startedAt: startedAt))
            }
        }

        var allJsonlSIDs: Set<String> = []
        let projectsDir = home.appendingPathComponent(".claude/projects")
        if let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) {
            for projDir in projects {
                if let jsonls = try? FileManager.default.contentsOfDirectory(
                    at: projDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                ) {
                    for jsonl in jsonls where jsonl.pathExtension == "jsonl" {
                        allJsonlSIDs.insert(jsonl.deletingPathExtension().lastPathComponent)
                    }
                }
            }
        }

        let grouped = Dictionary(grouping: aliveEntries) { allJsonlSIDs.contains($0.sid) }
        let goodEntries = grouped[true] ?? []
        let staleEntries = grouped[false] ?? []

        staleSessions = staleEntries.map {
            StaleSession(file: $0.file, pid: $0.pid, staleSID: $0.sid, startedAt: $0.startedAt)
        }

        activeSIDs.removeAll()
        sessionPIDMap.removeAll()
        for entry in goodEntries {
            activeSIDs.insert(entry.sid)
            sessionPIDMap[entry.sid] = entry.pid
        }

        // Hub enrichment (tags/descs) — injected by HubExtension if available
        hubTags.removeAll()
        hubDescs.removeAll()
        onEnrich?()
    }

    // MARK: - Session List Scanning

    func scanSessionsInBackground(completion: @escaping () -> Void) {
        if isScanning {
            DispatchQueue.main.async { completion() }
            return
        }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion() }
                return
            }
            self.scanActiveSessions()

            let scriptPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/自动化/scripts/scan-sessions.py").path

            guard FileManager.default.fileExists(atPath: scriptPath) else {
                DispatchQueue.main.async {
                    self.sessions = []
                    self.isScanning = false
                    completion()
                }
                return
            }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [scriptPath]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            process.environment = augmentedEnvironment()

            do {
                try process.run()
            } catch {
                os_log("scan-sessions.py failed: %{public}@", log: log, type: .error, error.localizedDescription)
                DispatchQueue.main.async {
                    self.sessions = []
                    self.isScanning = false
                    completion()
                }
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""

            let found = output.components(separatedBy: "\n").compactMap { line -> Session? in
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1E}")
                guard parts.count >= 4 else { return nil }
                return Session(display: parts[2], sid: parts[3], timestamp: TimeInterval(parts[0]) ?? 0, time: parts[1])
            }

            DispatchQueue.main.async {
                self.sessions = found
                self.isScanning = false
                completion()
            }
        }
    }
}
