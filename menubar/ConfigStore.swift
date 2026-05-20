import Foundation
import os

private let log = OSLog(subsystem: "com.linekforge.forge-launcher", category: "Config")

final class ConfigStore {
    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/状态/forge-launcher-config.json")

    private(set) var workingDir: String = "~"
    private(set) var authCheckEnabled: Bool = false
    private(set) var modelOverride: String = ""

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
            } else {
                os_log("load: 配置的工作目录不存在，回退到默认: %{public}@", log: log, type: .info, expanded)
            }
        }
        if let auth = obj["authCheckEnabled"] as? Bool {
            authCheckEnabled = auth
        }
        if let model = obj["modelOverride"] as? String {
            modelOverride = model
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

    func setModelOverride(_ model: String) {
        modelOverride = model.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// `--model 'xxx'` fragment for shell commands, empty if no override
    var modelFlag: String {
        guard !modelOverride.isEmpty else { return "" }
        let escaped = modelOverride.replacingOccurrences(of: "'", with: "'\\''")
        return " --model '\(escaped)'"
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
        if !modelOverride.isEmpty { obj["modelOverride"] = modelOverride }
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            os_log("ConfigStore save failed: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }
}
