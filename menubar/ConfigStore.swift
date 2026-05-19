import Foundation
import os

private let log = OSLog(subsystem: "com.linekforge.forge-launcher", category: "Config")

class ConfigStore {
    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/状态/forge-launcher-config.json")

    private(set) var workingDir: String = "~"
    private(set) var authCheckEnabled: Bool = false

    func load() {
        guard let data = try? Data(contentsOf: file) else {
            if FileManager.default.fileExists(atPath: file.path) {
                os_log("load: 配置文件存在但无法读取: %{public}@", log: log, type: .error, file.path)
            }
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            os_log("load: JSON 格式损坏，使用默认配置。文件: %{public}@", log: log, type: .error, file.path)
            return
        }
        if let dir = obj["defaultWorkDir"] as? String, !dir.isEmpty {
            let expanded = (dir as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                workingDir = dir
            }
        }
        if let auth = obj["authCheckEnabled"] as? Bool {
            authCheckEnabled = auth
        }
    }

    func setWorkingDir(_ dir: String) {
        workingDir = dir.isEmpty ? "~" : dir
        save()
    }

    func setAuthCheckEnabled(_ enabled: Bool) {
        authCheckEnabled = enabled
        save()
    }

    var shellWorkingDir: String {
        let expanded = (workingDir as NSString).expandingTildeInPath
        let escaped = expanded.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func save() {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var obj: [String: Any] = [:]
        if workingDir != "~" { obj["defaultWorkDir"] = workingDir }
        if authCheckEnabled { obj["authCheckEnabled"] = authCheckEnabled }
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            os_log("ConfigStore save failed: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }
}
