import Foundation
import os

private let log = OSLog(subsystem: "com.linekforge.forge-launcher", category: "Scanner")

final class SessionScanner {
    private(set) var sessions: [Session] = []
    private(set) var activeSIDs: Set<String> = []
    private(set) var sessionPIDMap: [String: Int] = [:]
    private(set) var staleSessions: [StaleSession] = []
    private(set) var failedJobs: [FailedJob] = []
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

    // MARK: - Failed Job Detection

    /// 扫 ~/.claude/jobs/<id>/state.json,只收 state=="failed" 的僵死 daemon job。
    ///
    /// ⚠️ predicate 严格只匹配 "failed"。实测 v2.1.154 的 state 词表含 done / blocked /
    /// failed: blocked 是 bg session 等待输入的存活态(daemon 还活着,只是 idle 等人),
    /// 误删 blocked job 的目录 = 干掉一个活 session 的足迹。done = 正常完成。
    /// 都不能进送葬清单。只有 failed(daemon 反复 --resume 死循环、不可恢复)才是真僵死。
    func scanFailedJobs() {
        failedJobs = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let jobsDir = home.appendingPathComponent(".claude/jobs")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: jobsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        for dir in dirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let stateFile = dir.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: stateFile),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = obj["state"] as? String,
                  state == "failed" else { continue }

            let jobId = dir.lastPathComponent
            let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? jobId
            let rawDetail = (obj["detail"] as? String) ?? (obj["intent"] as? String) ?? ""
            let detail = String(rawDetail.prefix(200))
            let sessionId = (obj["sessionId"] as? String) ?? ""
            failedJobs.append(FailedJob(jobId: jobId, dir: dir, name: name, detail: detail, sessionId: sessionId))
        }
    }

    // MARK: - Live Agent Probe（只读 oracle · #11/#12 §B 方向）

    /// 只读探测：跑 `claude agents --json` 取当前 live session 的 sessionId 集合。
    ///
    /// 这是 launcher 第一处、也是唯一一处 claude agents 依赖，方向对齐 #12 oracle，
    /// 但**只读、只在送葬前用一次**，不进周期扫描、不扩散成全局 liveness 改造（那是 §B 产品决定）。
    ///
    /// 返回 nil = 探测不可用（claude 没找到 / 超时 / 非零退出 / 解析失败）。
    /// ⚠️ 调用方必须把 nil 当"未知"优雅降级——**绝不能当成"没有 live session"**（那会误判活 job 可删）。
    /// 实测：state.json 的 state 会滞后于真实存活（done 的 job 进程可能还 busy），故 agents 列表
    /// 才是权威 liveness 信号。
    func liveAgentSessionIds(timeout: TimeInterval = 3.0) -> Set<String>? {
        let process = Process()
        // 用 /usr/bin/env + PATH 增强解析 claude（GUI app 无 shell PATH，复用 augmentedEnvironment）
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "agents", "--json"]
        process.environment = augmentedEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // 超时护栏：后台读管道，主等待超时则 terminate 并降级
        let group = DispatchGroup()
        group.enter()
        var data = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()   // SIGTERM；claude 正常会随之关 stdout 解开后台读线程。
            return nil            // 已降级返回，UI 不受影响（极端下后台读线程可能多挂一会，影响有界）
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return SessionScanner.parseLiveSessionIds(data)
    }

    /// 纯解析（可单测）：从 `claude agents --json` 输出抽 sessionId 集合。解析失败返 nil（降级）。
    static func parseLiveSessionIds(_ data: Data) -> Set<String>? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var ids = Set<String>()
        for obj in arr {
            if let sid = obj["sessionId"] as? String, !sid.isEmpty { ids.insert(sid) }
        }
        return ids
    }

    /// 纯判定（可单测）：给定 job 的 sessionId + live 集合（nil=探测不可用），判存活安全性。
    static func jobLiveness(sessionId: String, liveSessionIds: Set<String>?) -> JobLiveness {
        guard let live = liveSessionIds else { return .unknown }
        if sessionId.isEmpty { return .unknown }   // state.json 缺 sessionId → 无从对照
        return live.contains(sessionId) ? .live : .dead
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
            self.scanFailedJobs()

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
