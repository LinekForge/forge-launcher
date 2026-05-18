import Cocoa
import os

private let log = OSLog(subsystem: "com.linekforge.forge-launcher", category: "App")

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var popoverCtrl: SessionPopoverController!
    var eventMonitor: Any?
    var popoverClosing = false
    var refreshTimer: Timer?

    let terminal: TerminalAdapter = DynamicTerminal()
    let scanner = SessionScanner()
    let store = SessionStore()
    let descStore = SessionDescriptionStore()
    let config = ConfigStore()
    var hub: HubExtension?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动器 own 的会话名字本——加载 + 注入到 Hub 扩展（让 ChannelDialog 能读写）
        descStore.load()
        config.load()

        // Hub (optional — enriches scanner with tags/descs)
        hub = HubExtension(terminal: terminal, scanner: scanner, descStore: descStore, config: config)
        scanner.onEnrich = { [weak self] in self?.hub?.enrichScanResults() }

        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let iconPath = Bundle.main.path(forResource: "icon", ofType: "png"),
               let img = NSImage(contentsOfFile: iconPath) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                button.title = "F"
            }
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover
        popoverCtrl = SessionPopoverController()
        popoverCtrl.onOpen = { [weak self] sid in self?.openSession(sid) }
        popoverCtrl.onNew = { [weak self] in self?.launchNew() }
        popoverCtrl.onNewChannel = { [weak self] in self?.hub?.launchChannel() }
        popoverCtrl.onRename = { [weak self] sid in
            self?.hub?.renameSession(sid) { self?.scanAndSync() }
        }
        popoverCtrl.onHubName = { [weak self] sid in self?.hub?.hubNameSession(sid) }
        popoverCtrl.onResumeChannel = { [weak self] sid in
            self?.popover.performClose(nil)
            self?.hub?.resumeChannel(sid)
        }
        popoverCtrl.onRepair = { [weak self] in self?.repairStaleSessions() }
        popoverCtrl.onRefresh = { [weak self] in self?.scanAndSync() }
        popoverCtrl.onSettings = { [weak self] in self?.showSettings() }
        popoverCtrl.onQuit = { NSApplication.shared.terminate(nil) }
        popoverCtrl.onViewAll = { [weak self] in self?.openAllSessions() }
        popoverCtrl.onStar = { [weak self] sid in self?.toggleStar(sid) }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 500)
        popover.behavior = .transient
        popover.contentViewController = popoverCtrl
        popover.delegate = self

        // Keyboard shortcuts
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.popover.isShown else { return event }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "n": self.launchNew(); return nil
                case "t": self.hub?.launchChannel(); return nil
                default: break
                }
            }
            return event
        }

        store.loadStars()
        scanAndSync()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.scanAndSync()
        }
    }

    // MARK: - Popover

    @objc func togglePopover() {
        if popoverClosing { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.loadStars()
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
            syncDataToPopover()
        }
    }

    func popoverWillClose(_ notification: Notification) {
        popoverClosing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.popoverClosing = false
        }
    }

    func syncDataToPopover() {
        popoverCtrl.allSessions = scanner.sessions
        popoverCtrl.activeSIDs = scanner.activeSIDs
        popoverCtrl.starredSIDs = store.stars
        popoverCtrl.staleCount = scanner.staleSessions.count
        popoverCtrl.hubTags = scanner.hubTags
        popoverCtrl.hubDescs = scanner.hubDescs
        popoverCtrl.sessionDescs = descStore.snapshot()
        popoverCtrl.sessionPIDs = scanner.sessionPIDMap
        popoverCtrl.hubOnline = hub?.isHubOnline ?? false
        popoverCtrl.hubEverOnline = hub?.isHubEverOnline ?? false
        popoverCtrl.reload()
        popoverCtrl.refreshDone()
    }

    func scanAndSync() {
        scanner.scanSessionsInBackground { [weak self] in
            self?.descStore.load()   // reload from disk to pick up external edits
            self?.syncDataToPopover()
        }
    }

    // MARK: - Finder Toolbar

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            syncDataToPopover()
        }
        return false
    }

    // MARK: - Core Actions

    private func guardAuth() -> Bool {
        if config.authCheckEnabled && !isClaudeAuthenticated() {
            showAuthAlert(terminal: terminal)
            return false
        }
        return true
    }

    func launchNew() {
        guard guardAuth() else { return }
        popover.performClose(nil)
        terminal.openTerminal("cd \(config.shellWorkingDir) && claude")
    }

    func openSession(_ sid: String) {
        guard isValidUUID(sid) else { return }
        if let pid = scanner.sessionPIDMap[sid] {
            popover.performClose(nil)
            _ = terminal.focusTerminalWindow(forPID: pid)
            return
        }
        guard guardAuth() else { return }
        popover.performClose(nil)

        let sidPrefix = String(sid.prefix(8))
        let desc = descStore.description(sid) ?? scanner.hubDescs[sidPrefix] ?? ""
        if !desc.isEmpty {
            hub?.writeSessionFile(tag: "", description: desc, channels: [], history: [:])
        }

        terminal.openTerminal("cd \(config.shellWorkingDir) && claude --resume \(sid)")
    }

    func openAllSessions() {
        guard guardAuth() else { return }
        popover.performClose(nil)
        terminal.openTerminal("cd \(config.shellWorkingDir) && claude --resume")
    }

    func toggleStar(_ sid: String) {
        store.toggleStar(sid)
        syncDataToPopover()
    }

    func repairStaleSessions() {
        popover.performClose(nil)
        let home = FileManager.default.homeDirectoryForCurrentUser

        for stale in scanner.staleSessions {
            _ = terminal.focusTerminalWindow(forPID: stale.pid)
            let candidates = scanner.sessions.filter { !scanner.activeSIDs.contains($0.sid) }

            if candidates.isEmpty {
                let alert = NSAlert()
                alert.messageText = "未找到候选会话"
                alert.informativeText = "没有找到可以匹配的会话文件。"
                alert.runModal()
                continue
            }

            let displayList = candidates.map { s in
                "\(s.time)  \(s.display)"
            }
            let chosen = showChooseDialog(
                title: "修复未识别的会话",
                prompt: "刚才高亮的 Ghostty 窗口对应哪个会话？",
                items: displayList
            )
            guard let idx = chosen else { continue }

            let realSID = candidates[idx].sid
            let sessionData: [String: Any] = [
                "pid": stale.pid, "sessionId": realSID,
                "cwd": home.path, "startedAt": stale.startedAt * 1000,
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: sessionData, options: [.prettyPrinted])
                try data.write(to: stale.file, options: .atomic)
            } catch {
                os_log("repairStaleSessions write failed: %{public}@", log: log, type: .error, error.localizedDescription)
            }
        }
        scanAndSync()
    }

    func showSettings() {
        let alert = NSAlert()
        alert.messageText = "设置"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 68))

        let dirLabel = NSTextField(labelWithString: "默认工作目录：")
        dirLabel.frame = NSRect(x: 0, y: 44, width: 100, height: 20)
        dirLabel.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(dirLabel)

        let dirField = NSTextField(frame: NSRect(x: 104, y: 42, width: 190, height: 22))
        let expandedDir = (config.workingDir as NSString).expandingTildeInPath
        dirField.stringValue = expandedDir
        dirField.isEditable = false
        dirField.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(dirField)

        let browseBtn = NSButton(title: "选择…", target: nil, action: nil)
        browseBtn.frame = NSRect(x: 298, y: 40, width: 60, height: 24)
        browseBtn.bezelStyle = .rounded
        browseBtn.controlSize = .small
        container.addSubview(browseBtn)

        let authCheck = NSButton(checkboxWithTitle: "启动前检查登录状态", target: nil, action: nil)
        authCheck.frame = NSRect(x: 0, y: 12, width: 220, height: 18)
        authCheck.state = config.authCheckEnabled ? .on : .off
        container.addSubview(authCheck)

        let authHint = NSTextField(labelWithString: "每次启动会话前检查认证，可能有 1-2 秒延迟")
        authHint.frame = NSRect(x: 20, y: -4, width: 340, height: 14)
        authHint.font = NSFont.systemFont(ofSize: 10)
        authHint.textColor = .tertiaryLabelColor
        container.addSubview(authHint)

        alert.accessoryView = container

        let helper = SettingsBrowseHelper(field: dirField)
        browseBtn.target = helper
        browseBtn.action = #selector(SettingsBrowseHelper.browse(_:))

        let response = alert.runModal()
        _ = helper

        if response == .alertFirstButtonReturn {
            let newDir = dirField.stringValue
            if newDir != expandedDir { config.setWorkingDir(newDir) }
            let newAuth = authCheck.state == .on
            if newAuth != config.authCheckEnabled { config.setAuthCheckEnabled(newAuth) }
        }
    }

    func showChooseDialog(title: String, prompt: String, items: [String]) -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        alert.alertStyle = .informational

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 28), pullsDown: false)
        for item in items { popup.addItem(withTitle: item) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "跳过")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return popup.indexOfSelectedItem }
        return nil
    }

}

private class SettingsBrowseHelper: NSObject {
    let field: NSTextField
    init(field: NSTextField) { self.field = field; super.init() }
    @objc func browse(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
        }
    }
}
