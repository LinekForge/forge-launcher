import Cocoa
import os

private let modelsLog = OSLog(subsystem: "com.linekforge.forge-launcher", category: "Models")

// MARK: - Shared Helpers

/// Convert a string to its Latin (pinyin for Chinese) + stripped diacritics form.
/// "Forge引擎" → "forgeyin qing"
func toLatin(_ s: String) -> String {
    let mutable = NSMutableString(string: s)
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    return (mutable as String).lowercased()
}

/// Extract the suffix after the first "-" in an instance ID (e.g. "forge-12345" → "12345").
/// Returns the full string if no "-" is found.
func instanceIdSuffix(_ id: String) -> String {
    id.split(separator: "-", maxSplits: 1).last.map(String.init) ?? id
}

/// Environment with extra PATH entries for GUI app context (no shell profile).
func augmentedEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extra = "/opt/homebrew/bin:/usr/local/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
    if let existing = env["PATH"] {
        env["PATH"] = "\(extra):\(existing)"
    } else {
        env["PATH"] = "\(extra):/usr/bin:/bin"
    }
    return env
}

/// Fail-open auth check. Returns false only when `claude auth status` confirms not logged in.
func isClaudeAuthenticated(timeoutSeconds: Double = 3) -> Bool {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "auth", "status"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.environment = augmentedEnvironment()

    do {
        try process.run()
    } catch {
        os_log("auth check failed to start: %{public}@", log: modelsLog, type: .info, error.localizedDescription)
        return true
    }

    let pipeHandle = pipe.fileHandleForReading
    let readQueue = DispatchQueue(label: "auth-pipe-read")
    var pipeData = Data()
    readQueue.async { pipeData = pipeHandle.readDataToEndOfFile() }

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }
    if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        process.terminate()
        os_log("auth check timed out, assuming authenticated", log: modelsLog, type: .info)
        return true
    }
    let data = readQueue.sync { pipeData }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let loggedIn = obj["loggedIn"] as? Bool else {
        return true
    }
    return loggedIn
}

func showAuthAlert(terminal: TerminalAdapter) {
    let alert = NSAlert()
    alert.messageText = "Claude Code 未登录"
    alert.informativeText = "请在终端运行 claude auth login 完成登录，然后回到菜单栏重试。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "打开终端登录")
    alert.addButton(withTitle: "取消")
    if alert.runModal() == .alertFirstButtonReturn {
        terminal.openTerminal("claude auth login")
    }
}

// MARK: - Models

struct Session {
    let display: String
    let sid: String
    let timestamp: TimeInterval
    let time: String
}

enum DisplayItem {
    case header(String)
    case session(Session, isActive: Bool, displayName: String)
}

struct StaleSession {
    let file: URL
    let pid: Int
    let staleSID: String
    let startedAt: TimeInterval
}
