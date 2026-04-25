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
    var hub: HubExtension?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动器 own 的会话名字本——加载 + 注入到 Hub 扩展（让 ChannelDialog 能读写）
        descStore.load()

        // Hub (optional — enriches scanner with tags/descs)
        hub = HubExtension(terminal: terminal, scanner: scanner, descStore: descStore)
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
            self?.hub?.renameSession(sid, scanner: self!.scanner) { self?.scanAndSync() }
        }
        popoverCtrl.onHubName = { [weak self] sid in self?.hub?.hubNameSession(sid) }
        popoverCtrl.onResumeChannel = { [weak self] sid in
            self?.popover.performClose(nil)
            self?.hub?.resumeChannel(sid)
        }
        popoverCtrl.onRepair = { [weak self] in self?.repairStaleSessions() }
        popoverCtrl.onRefresh = { [weak self] in self?.refreshSessions() }
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
        popoverCtrl.sessionNames = [:]
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

    func launchNew() {
        popover.performClose(nil)
        terminal.openTerminal("cd ~ && claude")
    }

    func openSession(_ sid: String) {
        popover.performClose(nil)
        if let pid = scanner.sessionPIDMap[sid], terminal.focusTerminalWindow(forPID: pid) { return }

        // 把描述传给即将启动的 client（写进 next-session.json 让 Hub ready 时能拿到）。
        // 优先级：启动器本地 store（权威） → Hub hubDescs（兼容历史）
        let sidPrefix = String(sid.prefix(8))
        let desc = descStore.description(sid) ?? scanner.hubDescs[sidPrefix] ?? ""
        if !desc.isEmpty {
            hub?.writeSessionFile(tag: "", description: desc, channels: [], history: [:])
        }

        terminal.openTerminal("cd ~ && claude --resume \(sid)")
    }

    func openAllSessions() {
        popover.performClose(nil)
        terminal.openTerminal("cd ~ && claude --resume")
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

    func refreshSessions() {
        scanAndSync()
    }
}
