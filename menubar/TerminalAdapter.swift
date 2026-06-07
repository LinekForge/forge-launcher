import Cocoa
import os

private let log = OSLog(subsystem: "com.linekforge.forge-launcher", category: "Terminal")

// MARK: - Protocol

protocol TerminalAdapter {
    func openTerminal(_ command: String)
    func focusTerminalWindow(forPID pid: Int) -> Bool
}

// MARK: - Shared Helpers

private func escapeForAppleScript(_ command: String) -> String {
    command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Run an AppleScript and log errors. Returns the result descriptor (nil on failure).
@discardableResult
private func runAppleScript(_ source: String, label: String) -> NSAppleEventDescriptor? {
    let script = NSAppleScript(source: source)
    var errorDict: NSDictionary?
    let result = script?.executeAndReturnError(&errorDict)
    if let err = errorDict {
        os_log("%{public}@ failed: %{public}@", log: log, type: .error, label, err.description)
    }
    return result
}

/// PID → TTY name (e.g. "ttys003"). Returns nil if PID not found or ps fails.
private func ttyForPID(_ pid: Int) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "tty=", "-p", "\(pid)"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        os_log("ps failed for PID %d: %{public}@", log: log, type: .error, pid, error.localizedDescription)
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty || name == "??") ? nil : name
}

// MARK: - Dynamic Terminal (auto-detect on every call)

/// 每次 openTerminal / focusTerminalWindow 时动态检测当前跑着什么终端。
/// Ghostty 在跑就用 Ghostty，否则 Terminal.app 兜底。
/// 用户中途启动 Ghostty——下一次操作自动切过去，不用重启 Launcher。
final class DynamicTerminal: TerminalAdapter {
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
        if apps.contains(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }) {
            if lastType != "iterm2" {
                lastType = "iterm2"
                os_log("Terminal: → iTerm2", log: log, type: .info)
            }
            return ITerm2Terminal()
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

final class GhosttyTerminal: TerminalAdapter {

    func openTerminal(_ command: String) {
        let escaped = escapeForAppleScript(command)
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
        runAppleScript(script, label: "Ghostty openTerminal")
    }

    func focusTerminalWindow(forPID pid: Int) -> Bool {
        guard let ttyName = ttyForPID(pid) else { return false }

        let ttyKey = "/dev/\(ttyName)".replacingOccurrences(of: "/", with: "_")
        let breadcrumbFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ghostty-ttys/\(ttyKey)")
        guard let termID = try? String(contentsOf: breadcrumbFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !termID.isEmpty else {
            os_log("No breadcrumb for TTY %{public}@", log: log, type: .info, ttyName)
            return false
        }

        let script = """
        tell application "Ghostty"
            repeat with t in every terminal
                if (id of t as text) is "\(escapeForAppleScript(termID))" then
                    focus t
                    return true
                end if
            end repeat
        end tell
        return false
        """
        return runAppleScript(script, label: "Ghostty focus")?.booleanValue ?? false
    }
}

// MARK: - Terminal.app Implementation

final class AppleTerminal: TerminalAdapter {

    func openTerminal(_ command: String) {
        let escaped = escapeForAppleScript(command)
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        runAppleScript(script, label: "Terminal.app openTerminal")
    }

    func focusTerminalWindow(forPID pid: Int) -> Bool {
        guard let ttyName = ttyForPID(pid) else { return false }

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
        return runAppleScript(script, label: "Terminal.app focus")?.booleanValue ?? false
    }
}

// MARK: - iTerm2 Implementation

final class ITerm2Terminal: TerminalAdapter {

    func openTerminal(_ command: String) {
        let escaped = escapeForAppleScript(command)
        let script = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "\(escaped)"
            end tell
        end tell
        """
        runAppleScript(script, label: "iTerm2 openTerminal")
    }

    func focusTerminalWindow(forPID pid: Int) -> Bool {
        guard let ttyName = ttyForPID(pid) else { return false }

        let fullTTY = "/dev/\(ttyName)"
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(fullTTY)" then
                            select s
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
        return runAppleScript(script, label: "iTerm2 focus")?.booleanValue ?? false
    }
}
