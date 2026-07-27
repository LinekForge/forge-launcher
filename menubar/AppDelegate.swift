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
        deployScanScript()
        descStore.load()
        config.load()

        hub = HubExtension(terminal: terminal, scanner: scanner, descStore: descStore, config: config)
        scanner.onEnrich = { [weak self] in self?.hub?.enrichScanResults() }

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
        popoverCtrl.onPurgeJobs = { [weak self] in self?.purgeFailedJobs() }
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

    private func deployScanScript() {
        guard let src = Bundle.main.path(forResource: "scan-sessions", ofType: "py") else {
            os_log(.error, log: log, "scan-sessions.py not found in bundle")
            return
        }
        let dst = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/自动化/scripts/scan-sessions.py")
        let dstDir = dst.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        } catch {
            os_log(.error, log: log, "Failed to create script dir: %{public}@", error.localizedDescription)
            return
        }
        if !FileManager.default.fileExists(atPath: dst.path) {
            do {
                try FileManager.default.copyItem(atPath: src, toPath: dst.path)
            } catch {
                os_log(.error, log: log, "Failed to copy scan script: %{public}@", error.localizedDescription)
            }
        } else if let srcData = FileManager.default.contents(atPath: src),
                  let dstData = FileManager.default.contents(atPath: dst.path),
                  srcData != dstData {
            do {
                try FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(atPath: src, toPath: dst.path)
            } catch {
                os_log(.error, log: log, "Failed to update scan script: %{public}@", error.localizedDescription)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Popover

    @objc func togglePopover() {
        guard !popoverClosing else { return }
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
        popoverCtrl.failedJobCount = scanner.failedJobs.count
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            scanAndSync()
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
        terminal.openTerminal("cd \(config.shellWorkingDir) && claude\(config.modelFlag)")
    }

    func openSession(_ sid: String) {
        guard isValidUUID(sid) else {
            os_log("openSession: invalid UUID %{public}@", log: log, type: .error, sid)
            return
        }
        // 活跃会话：聚焦已有终端窗口即可，不新开终端
        if let pid = scanner.sessionPIDMap[sid], terminal.focusTerminalWindow(forPID: pid) {
            popover.performClose(nil)
            return
        }
        guard guardAuth() else { return }
        popover.performClose(nil)

        // 预写描述到 next-session.json，让 claude --resume 后 Hub 能识别这个会话
        let sidPrefix = String(sid.prefix(8))
        let desc = descStore.description(sid) ?? scanner.hubDescs[sidPrefix] ?? ""
        if !desc.isEmpty {
            hub?.writeSessionFile(tag: "", description: desc, channels: [], history: [:])
        }

        terminal.openTerminal("cd \(config.shellWorkingDir) && claude\(config.modelFlag) --resume \(sid)")
    }

    func openAllSessions() {
        guard guardAuth() else { return }
        popover.performClose(nil)
        terminal.openTerminal("cd \(config.shellWorkingDir) && claude\(config.modelFlag) --resume")
    }

    func toggleStar(_ sid: String) {
        store.toggleStar(sid)
        syncDataToPopover()
    }

    // MARK: - Dialogs

    func repairStaleSessions() {
        popover.performClose(nil)
        let home = FileManager.default.homeDirectoryForCurrentUser

        let candidates = scanner.sessions.filter { !scanner.activeSIDs.contains($0.sid) }
        for stale in scanner.staleSessions {
            _ = terminal.focusTerminalWindow(forPID: stale.pid)

            if candidates.isEmpty {
                let alert = NSAlert()
                alert.messageText = "没有可用的会话"
                alert.informativeText = "当前没有可以关联的会话记录。"
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
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stale.file.path)
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

        let allChannels = hub?.client.fetchHubChannels() ?? []
        let channelRowHeight: CGFloat = 20
        let channelBlockHeight = allChannels.isEmpty ? 0 : channelRowHeight * CGFloat(allChannels.count) + 24
        let containerHeight: CGFloat = 120 + channelBlockHeight

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: containerHeight))
        var y = containerHeight

        y -= 24
        let dirLabel = NSTextField(labelWithString: "默认工作目录：")
        dirLabel.frame = NSRect(x: 0, y: y, width: 100, height: 20)
        dirLabel.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(dirLabel)

        let dirField = NSTextField(frame: NSRect(x: 104, y: y - 2, width: 190, height: 22))
        let expandedDir = (config.workingDir as NSString).expandingTildeInPath
        dirField.stringValue = expandedDir
        dirField.isEditable = false
        dirField.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(dirField)

        let browseBtn = NSButton(title: "选择…", target: nil, action: nil)
        browseBtn.frame = NSRect(x: 298, y: y - 2, width: 60, height: 24)
        browseBtn.bezelStyle = .rounded
        browseBtn.controlSize = .small
        container.addSubview(browseBtn)

        y -= 28
        let modelLabel = NSTextField(labelWithString: "模型：")
        modelLabel.frame = NSRect(x: 0, y: y, width: 100, height: 20)
        modelLabel.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(modelLabel)

        // 维护模型列表：
        // 1. 终端跑 /model 看 CC 当前支持哪些模型和显示名
        // 2. 用 `claude --model '<id>' -p "你的 model ID 和 context window?"` 验证 ID 和 context 大小
        // 3. 格式可能随 CC 版本变化——以实测为准，不要假设
        let modelOptions = [
            ("", "默认（跟随 CC 配置）"),
            ("claude-opus-4-8", "Opus 4.8 · 1M"),
            ("claude-opus-4-7", "Opus 4.7 · 1M"),
            ("claude-opus-4-6[1m]", "Opus 4.6 · 1M"),
            ("claude-opus-4-6", "Opus 4.6 · 200K"),
            ("claude-sonnet-4-6[1m]", "Sonnet 4.6 · 1M"),
            ("claude-sonnet-4-6", "Sonnet 4.6 · 200K"),
            ("claude-haiku-4-5", "Haiku 4.5 · 200K"),
            ("claude-fable-5", "Fable 5 · 1M"),
        ]
        let modelPopup = NSPopUpButton(frame: NSRect(x: 104, y: y - 2, width: 254, height: 24), pullsDown: false)
        for (_, label) in modelOptions { modelPopup.addItem(withTitle: label) }
        if let idx = modelOptions.firstIndex(where: { $0.0 == config.modelOverride }) {
            modelPopup.selectItem(at: idx)
        }
        container.addSubview(modelPopup)

        var channelChecks: [(id: String, check: NSButton)] = []
        if !allChannels.isEmpty {
            y -= 24
            let chLabel = NSTextField(labelWithString: "通道（取消勾选的不显示在弹窗里）：")
            chLabel.frame = NSRect(x: 0, y: y, width: 360, height: 16)
            chLabel.font = NSFont.systemFont(ofSize: 11)
            chLabel.textColor = .secondaryLabelColor
            container.addSubview(chLabel)

            for ch in allChannels {
                y -= channelRowHeight
                let chk = NSButton(checkboxWithTitle: ch.name, target: nil, action: nil)
                chk.frame = NSRect(x: 16, y: y, width: 200, height: 18)
                chk.font = NSFont.systemFont(ofSize: 12)
                let enabled = config.enabledChannels.isEmpty || config.enabledChannels.contains(ch.id)
                chk.state = enabled ? .on : .off
                container.addSubview(chk)
                channelChecks.append((id: ch.id, check: chk))
            }
        }

        y -= 28
        let histLabel = NSTextField(labelWithString: "默认历史条数：")
        histLabel.frame = NSRect(x: 0, y: y, width: 100, height: 20)
        histLabel.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(histLabel)

        let histCombo = NSComboBox(frame: NSRect(x: 104, y: y - 2, width: 80, height: 24))
        histCombo.isEditable = true
        histCombo.addItems(withObjectValues: ["0", "50", "100", "200", "500"])
        histCombo.stringValue = "\(config.defaultHistoryCount)"
        histCombo.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        container.addSubview(histCombo)

        let histUnit = NSTextField(labelWithString: "条")
        histUnit.frame = NSRect(x: 188, y: y, width: 30, height: 18)
        histUnit.font = NSFont.systemFont(ofSize: 12)
        histUnit.textColor = .secondaryLabelColor
        container.addSubview(histUnit)

        y -= 24
        let authCheck = NSButton(checkboxWithTitle: "启动前检查登录状态", target: nil, action: nil)
        authCheck.frame = NSRect(x: 0, y: y, width: 220, height: 18)
        authCheck.state = config.authCheckEnabled ? .on : .off
        container.addSubview(authCheck)

        y -= 16
        let authHint = NSTextField(labelWithString: "每次启动会话前检查认证，可能有 1-2 秒延迟")
        authHint.frame = NSRect(x: 20, y: y, width: 340, height: 14)
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
            let newModel = modelOptions[modelPopup.indexOfSelectedItem].0
            if newModel != config.modelOverride { config.setModelOverride(newModel) }

            if !channelChecks.isEmpty {
                let allOn = channelChecks.allSatisfy { $0.check.state == .on }
                let enabled = allOn ? [] : channelChecks.filter { $0.check.state == .on }.map { $0.id }
                if enabled != config.enabledChannels { config.setEnabledChannels(enabled) }
            }

            let newHist = Int(histCombo.stringValue) ?? 100
            if newHist != config.defaultHistoryCount { config.setDefaultHistoryCount(newHist) }

            let newAuth = authCheck.state == .on
            if newAuth != config.authCheckEnabled { config.setAuthCheckEnabled(newAuth) }
        }
    }

    /// 处理 state=="failed" 僵死 daemon job。送葬前跑只读存活探测（claude agents --json），
    /// 按诊断**分两条路**（用户手动点红条触发，是继 repairStaleSessions 之后第二个写/删 CC 文件的场景）：
    ///  - **live**（failed + sessionId 仍在 agents 列表）= 进程还活、有对话有工作，没真死
    ///    → ⏹ `claude stop <jobId>`：终止进程**但保留对话**（可 `claude attach` 恢复），**不删目录**。
    ///      实测停后 state → "stopped"，自动掉出 state=="failed" 红条，不会被再当尸体催删。
    ///  - **dead**（failed + 不在 agents 列表）= 进程已亡、无可恢复 = 真坏的尸体
    ///    → 🗑 removeItem 删 ~/.claude/jobs/<id>/（不可恢复）。
    ///  - **unknown**：probe 不可用（liveSessionIds==nil）→ 保守退回「带警告的纯删」；
    ///    probe 可用但该 job 缺 sessionId → 跳过，不自动选破坏动作。
    func purgeFailedJobs() {
        popover.performClose(nil)
        let jobs = scanner.failedJobs
        if jobs.isEmpty { return }

        // 只读存活探测放后台跑（claude agents 子进程最长 timeout，不冻结 UI）。
        // 护栏（降级）：probe nil → unknown → 不自动选破坏动作（见 presentPurgeFlow）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let liveIds = self?.scanner.liveAgentSessionIds()
            DispatchQueue.main.async {
                self?.presentPurgeFlow(jobs: jobs, liveSessionIds: liveIds)
            }
        }
    }

    /// 按 probe 诊断把 jobs 分成 停用/删除/跳过 三桶，弹 overview 确认，继续后：
    /// 后台跑 claude stop（不冻结 UI）→ 回主线程报告停用失败 + 对删除做不可恢复二次确认。
    private func presentPurgeFlow(jobs: [FailedJob], liveSessionIds: Set<String>?) {
        let probeDown = (liveSessionIds == nil)
        var stopTargets: [FailedJob] = [], deleteTargets: [FailedJob] = [], skipTargets: [FailedJob] = []
        for job in jobs {
            switch SessionScanner.jobLiveness(sessionId: job.sessionId, liveSessionIds: liveSessionIds) {
            case .live:    stopTargets.append(job)
            case .dead:    deleteTargets.append(job)
            case .unknown: probeDown ? deleteTargets.append(job) : skipTargets.append(job)
            }
        }

        func line(_ j: FailedJob, _ kind: String) -> String {
            let d = j.detail.isEmpty ? "" : "\n    \(j.detail.prefix(70))"
            return "\(kind) \(j.name)  [\(j.jobId)]\(d)"
        }
        var lines: [String] = []
        lines += stopTargets.map { line($0, "⏹ 停用(保留对话)") }
        lines += deleteTargets.map { line($0, "🗑 删除(不可恢复)") }
        lines += skipTargets.map { line($0, "⏭ 跳过(状态未知)") }

        let overview = NSAlert()
        overview.messageText = "处理 \(jobs.count) 个僵死任务"
        var info = ""
        if probeDown { info += "⚠ 未能核对进程存活（claude agents 不可用），以下按「删除残留」保守处理。\n\n" }
        info += "继续将执行：\n" + lines.joined(separator: "\n")
        if !stopTargets.isEmpty {
            info += "\n\n⏹ 停用 = `claude stop`：终止进程但保留对话，可 `claude attach` 恢复，不删目录。"
        }
        overview.informativeText = info
        overview.alertStyle = .warning
        overview.addButton(withTitle: "取消")   // 默认（Return）= 安全
        overview.addButton(withTitle: "继续")
        guard overview.runModal() == .alertSecondButtonReturn else { return }

        // 停用（claude stop 子进程）放后台跑，不冻结 UI；完了回主线程报告 + 做删除二次确认。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var stopFailed: [FailedJob] = []
            for job in stopTargets {
                if !self.scanner.stopAgentSession(jobId: job.jobId, sessionId: job.sessionId) {
                    stopFailed.append(job)   // 不假装停了
                }
            }
            DispatchQueue.main.async {
                self.finishPurge(deleteTargets: deleteTargets, stopFailed: stopFailed)
            }
        }
    }

    /// 报告 claude stop 失败（不静默吞）+ 对「删除残留」做不可恢复的二次确认。
    private func finishPurge(deleteTargets: [FailedJob], stopFailed: [FailedJob]) {
        if !stopFailed.isEmpty {
            let a = NSAlert()
            a.messageText = "⏹ \(stopFailed.count) 个停用未确认成功"
            a.informativeText = "claude stop 未确认这些已停（退出码非 0 或仍在 agents 列表），未动它们的目录：\n"
                + stopFailed.map { "• \($0.name) [\($0.jobId)]" }.joined(separator: "\n")
                + "\n\n可手动 `claude stop <id>`，或 `claude agents` 查看。"
            a.alertStyle = .warning
            a.runModal()
        }
        if !deleteTargets.isEmpty {
            let del = NSAlert()
            del.messageText = "🗑 删除 \(deleteTargets.count) 个残留目录？"
            del.informativeText = "此操作不可恢复，删除 ~/.claude/jobs/<id>/（仅死掉的尸体，不影响其他会话）：\n"
                + deleteTargets.map { "• \($0.name) [\($0.jobId)]" }.joined(separator: "\n")
            del.alertStyle = .critical
            del.addButton(withTitle: "取消")   // 默认（Return）= 安全
            del.addButton(withTitle: "删除（不可恢复）")
            if del.runModal() == .alertSecondButtonReturn {
                for job in deleteTargets {
                    do {
                        try FileManager.default.removeItem(at: job.dir)
                    } catch {
                        os_log("purge remove failed (%{public}@): %{public}@",
                               log: log, type: .error, job.jobId, error.localizedDescription)
                    }
                }
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
