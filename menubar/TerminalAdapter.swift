import Cocoa
import os

private let log = OSLog(subsystem: "com.linekforge.forge-launcher", category: "Terminal")

// MARK: - Protocol

protocol TerminalAdapter {
    func openTerminal(_ command: String)
    func focusTerminalWindow(forPID pid: Int) -> Bool
}

// MARK: - Dynamic Terminal (auto-detect on every call)

/// 每次 openTerminal / focusTerminalWindow 时动态检测当前跑着什么终端。
/// Ghostty 在跑就用 Ghostty，否则 Terminal.app 兜底。
/// 用户中途启动 Ghostty——下一次操作自动切过去，不用重启 Launcher。
class DynamicTerminal: TerminalAdapter {
    private var lastType: String = ""

    private func current() -> TerminalAdapter {
        let apps = NSWorkspace.shared.runningApplications
        if apps.contains(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" }) {
            if lastType != "ghostty" {
                lastType = "ghostty"
                os_log("Terminal: → Ghostty", log: log, type: .info)
            }
            return GhosttyTerminal()
        }
        if lastType != "terminal" {
            lastType = "terminal"
            os_log("Terminal: → Terminal.app", log: log, type: .info)
        }
        return AppleTerminal()
    }

    func openTerminal(_ command: String) {
        current().openTerminal(command)
    }

    func focusTerminalWindow(forPID pid: Int) -> Bool {
        return current().focusTerminalWindow(forPID: pid)
    }
}

// MARK: - Ghostty Implementation

class GhosttyTerminal: TerminalAdapter {

    func openTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Ghostty"
            activate
            set win to new window
            set term to focused terminal of selected tab of win
            set termId to id of term
            set breadcrumb to "mkdir -p ~/.claude/ghostty-ttys && echo '" & termId & "' > ~/.claude/ghostty-ttys/$(tty | tr '/' '_')"
            input text breadcrumb to term
            send key "enter" to term
            delay 0.3
            input text "\(escaped)" to term
            send key "enter" to term
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)
        if let err = errorDict {
            os_log("Ghostty openTerminal failed: %{public}@", log: log, type: .error, err.description)
        }
    }

    func focusTerminalWindow(forPID pid: Int) -> Bool {
        // Step 1: PID → TTY
        let ttyProcess = Process()
        let ttyPipe = Pipe()
        ttyProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
        ttyProcess.arguments = ["-o", "tty=", "-p", "\(pid)"]
        ttyProcess.standardOutput = ttyPipe
        ttyProcess.standardError = FileHandle.nullDevice
        do { try ttyProcess.run(); ttyProcess.waitUntilExit() } catch {
            os_log("ps failed for PID %d: %{public}@", log: log, type: .error, pid, error.localizedDescription)
            return false
        }

        let ttyData = ttyPipe.fileHandleForReading.readDataToEndOfFile()
        let ttyName = String(data: ttyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ttyName.isEmpty { return false }

        // Step 2: TTY → terminal ID (read breadcrumb file)
        let ttyKey = "/dev/\(ttyName)".replacingOccurrences(of: "/", with: "_")
        let breadcrumbFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ghostty-ttys/\(ttyKey)")
        guard let termID = try? String(contentsOf: breadcrumbFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !termID.isEmpty else {
            os_log("No breadcrumb for TTY %{public}@", log: log, type: .info, ttyName)
            return false
        }

        // Step 3: terminal ID → focus
        let script = """
        tell application "Ghostty"
            repeat with t in every terminal
                if id of t is "\(termID)" then
                    focus t
                    return true
                end if
            end repeat
        end tell
        return false
        """
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)
        if let err = errorDict {
            os_log("Ghostty focus failed: %{public}@", log: log, type: .error, err.description)
        }
        return result?.booleanValue ?? false
    }
}

// MARK: - Terminal.app Implementation

/// macOS 原生 Terminal.app——每台 Mac 都有，做 fallback 完美。
/// 比 Ghostty 简单：Terminal.app 原生暴露每个 tab 的 TTY，不需要 breadcrumb 桥接。
class AppleTerminal: TerminalAdapter {

    func openTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)
        if let err = errorDict {
            os_log("Terminal.app openTerminal failed: %{public}@", log: log, type: .error, err.description)
        }
    }

    func focusTerminalWindow(forPID pid: Int) -> Bool {
        // Step 1: PID → TTY
        let ttyProcess = Process()
        let ttyPipe = Pipe()
        ttyProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
        ttyProcess.arguments = ["-o", "tty=", "-p", "\(pid)"]
        ttyProcess.standardOutput = ttyPipe
        ttyProcess.standardError = FileHandle.nullDevice
        do { try ttyProcess.run(); ttyProcess.waitUntilExit() } catch {
            os_log("ps failed for PID %d: %{public}@", log: log, type: .error, pid, error.localizedDescription)
            return false
        }

        let ttyData = ttyPipe.fileHandleForReading.readDataToEndOfFile()
        let ttyName = String(data: ttyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ttyName.isEmpty { return false }

        // Step 2: TTY → Terminal.app tab（原生暴露 tty，不需要 breadcrumb）
        let fullTTY = "/dev/\(ttyName)"
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(fullTTY)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)
        if let err = errorDict {
            os_log("Terminal.app focus failed: %{public}@", log: log, type: .error, err.description)
        }
        return result?.booleanValue ?? false
    }
}
