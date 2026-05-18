import Cocoa
import os

private let authLog = OSLog(subsystem: "com.linekforge.forge-launcher", category: "AuthGuard")

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
        os_log("auth check failed to start: %{public}@", log: authLog, type: .info, error.localizedDescription)
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
        os_log("auth check timed out, assuming authenticated", log: authLog, type: .info)
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
