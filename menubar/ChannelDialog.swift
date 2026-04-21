import Cocoa
import os

private let log = OSLog(subsystem: "com.linekforge.forge-launcher", category: "ChannelDialog")

/// 所有 NSAlert 弹窗 + flow orchestration（用户交互 → client API/文件 → terminal 启动）。
/// 持有 HubClient / TerminalAdapter / SessionScanner 引用——每个 method 完成一个完整的用户动作。
class ChannelDialog {
    let client: HubClient
    let terminal: TerminalAdapter
    let scanner: SessionScanner
    let descStore: SessionDescriptionStore

    init(client: HubClient, terminal: TerminalAdapter, scanner: SessionScanner, descStore: SessionDescriptionStore) {
        self.client = client
        self.terminal = terminal
        self.scanner = scanner
        self.descStore = descStore
    }

    // MARK: - Launch Channel

    /// 点"📡 通道会话"按钮的入口：描述+标签+预设三输入，或走"自定义..."。
    func launch() {
        let hubChannels = client.fetchHubChannels()
        let presets = client.loadPresets()

        let alert = NSAlert()
        alert.messageText = "通道会话"
        alert.informativeText = "描述：显示在回复标识里（如 Forge引擎）\n标签:微信里 @ 用的（如 P），留空自动分配"
        alert.addButton(withTitle: "启动")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "自定义...")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 90))

        let descInput = NSTextField(frame: NSRect(x: 0, y: 64, width: 300, height: 24))
        descInput.placeholderString = "描述（如：Forge引擎、日常、项目）"
        container.addSubview(descInput)

        let tagInput = NSTextField(frame: NSRect(x: 0, y: 36, width: 300, height: 24))
        tagInput.placeholderString = "@标签（如:P、A、日）"
        container.addSubview(tagInput)

        let presetLabel = NSTextField(labelWithString: "📡")
        presetLabel.frame = NSRect(x: 0, y: 6, width: 20, height: 22)
        container.addSubview(presetLabel)

        let presetPopup = NSPopUpButton(frame: NSRect(x: 22, y: 4, width: 278, height: 26), pullsDown: false)
        presetPopup.addItem(withTitle: "全通道（默认）")
        for p in presets {
            presetPopup.addItem(withTitle: p.name)
        }
        container.addSubview(presetPopup)

        alert.accessoryView = container
        alert.window.initialFirstResponder = descInput

        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return }

        let desc = descInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var tag = tagInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.isEmpty && !desc.isEmpty { tag = client.suggestTag(from: desc) }

        if response == .alertThirdButtonReturn {
            launchCustom(hubChannels: hubChannels, desc: desc, tag: tag)
            return
        }

        let selectedIdx = presetPopup.indexOfSelectedItem
        var subscribe: [String]
        var history: [String: Int]

        if selectedIdx == 0 {
            subscribe = hubChannels.map { $0.id }
            history = Dictionary(uniqueKeysWithValues: hubChannels.map { ($0.id, 100) })
        } else {
            let preset = presets[selectedIdx - 1]
            subscribe = preset.subscribe
            history = preset.history
        }

        client.writeSessionFile(tag: tag, description: desc, channels: subscribe, history: history)
        terminal.openTerminal("cd ~ && claude --dangerously-load-development-channels server:hub server:engine")
    }

    // MARK: - Custom Launch

    private func launchCustom(hubChannels: [HubClient.ChannelMeta], desc: String, tag: String) {
        guard let result = promptChannelConfigDialog(
            title: "自定义通道配置",
            hubChannels: hubChannels,
            preselectedChannels: nil,
            allowSavePreset: true
        ) else { return }

        if result.savePreset {
            let nameAlert = NSAlert()
            nameAlert.messageText = "保存为预设"
            nameAlert.addButton(withTitle: "保存并启动")
            nameAlert.addButton(withTitle: "取消")
            let nameInput = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            nameInput.placeholderString = "预设名称（如：只微信、日常）"
            nameAlert.accessoryView = nameInput
            nameAlert.window.initialFirstResponder = nameInput
            let nameResponse = nameAlert.runModal()
            if nameResponse == .alertSecondButtonReturn { return }
            let presetName = nameInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !presetName.isEmpty {
                client.savePreset(HubClient.ChannelPreset(name: presetName, subscribe: result.subscribe, history: result.history))
            }
        }

        client.writeSessionFile(tag: tag, description: desc, channels: result.subscribe, history: result.history)
        terminal.openTerminal("cd ~ && claude --dangerously-load-development-channels server:hub server:engine")
    }

    // MARK: - Resume Channel

    /// 右键非活跃 session 的"📡 通道恢复"入口：
    /// - description/tag 优先从启动器本地 store 拿（权威）
    /// - channels 仍从 Hub identities 拿（channels 是 Hub 业务，Hub own）
    /// - 弹对话框让用户调整订阅和历史条数，然后 `claude --resume <sid> --dangerously-load-*`
    func resume(sid: String) {
        let sidPrefix = String(sid.prefix(8))
        // Hub identities 里的条目——主要为了拿 channels（历史兼容也能给 tag/desc 兜底）
        let hubSaved = client.lookupSavedIdentity(sidPrefix: sidPrefix)

        // description / tag：本地 store 优先
        let tag = descStore.tag(sid) ?? hubSaved.tag
        let desc = descStore.description(sid) ?? hubSaved.desc
        let savedChannels = hubSaved.channels

        let hubChannels = client.fetchHubChannels()
        // 没存过 / 存的是 "all" → 全勾选；否则按 saved 集合勾选
        let preselected: Set<String>? = (savedChannels.isEmpty || savedChannels == ["all"])
            ? nil
            : Set(savedChannels)
        let titleSuffix = desc.isEmpty ? "" : "：\(desc)"

        guard let result = promptChannelConfigDialog(
            title: "Resume 通道会话\(titleSuffix)",
            hubChannels: hubChannels,
            preselectedChannels: preselected,
            allowSavePreset: false
        ) else { return }

        client.writeSessionFile(tag: tag, description: desc, channels: result.subscribe, history: result.history)
        terminal.openTerminal("cd ~ && claude --resume \(sid) --dangerously-load-development-channels server:hub server:engine")
    }

    // MARK: - Hub Naming (tag)

    /// 右键活跃 session 的"📡 标签..."入口。
    ///
    /// tag 也走"启动器本地 store 为准 + best-effort 通知 Hub"模式（和 rename 一致）。
    /// tag 比 description 更 Hub-业务导向（微信 @ 路由直接依赖），但 UI 层的显示归属仍是启动器。
    func hubName(sid: String) {
        guard let pid = scanner.sessionPIDMap[sid] else { return }
        let instanceId = "\(client.instancePrefix)\(pid)"

        let alert = NSAlert()
        alert.messageText = "标签"
        alert.informativeText = "微信里用 @标签 定向发消息。\n建议用单个字母，方便输入。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let sidPrefix = String(sid.prefix(8))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        // 预填：本地 store 优先，fallback Hub
        input.stringValue = descStore.tag(sid) ?? scanner.hubTags[sidPrefix] ?? ""
        input.placeholderString = "@标签（如 P、A、日）"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // 1. 先写本地 store
            descStore.setTag(sid, tag: name)
            // 2. best-effort Hub（tag 不空才发——Hub 没有 "清除 tag" 的清晰语义）
            if !name.isEmpty {
                client.setTag(instanceId: instanceId, tag: name)
            }
        }
    }

    // MARK: - Rename (description)

    /// 右键任意 session 的"📝 描述..."入口。
    ///
    /// 新架构（2026-04-19 晚）：启动器本地 store 是 source of truth，Hub 是可选下游。
    /// - 写本地 store 成功 = 用户看到的反馈是真实的
    /// - Hub POST 是 best-effort（给 peer 模式会话的回复标识用），失败不 block 也不回退
    /// - 不再写 Hub own 的 identities 文件（那是 Hub 自己的 state，外部 writer 引发 race）
    /// - 非活跃会话也能 rename——启动器的命名不受 Hub peer 状态制约
    func rename(sid: String, onDone: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "描述"
        alert.informativeText = "会话的显示名字，立即生效、永久保存在启动器本地。\n留空则清除。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let sidPrefix = String(sid.prefix(8))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        // 预填：本地 store 优先，fallback 到 Hub 的兼容数据
        input.stringValue = descStore.description(sid) ?? scanner.hubDescs[sidPrefix] ?? ""
        input.placeholderString = "描述（如：Forge引擎、日常、项目）"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            // 1. 先写本地 store——source of truth，sync write，成功即真成功
            let ok = descStore.setDescription(sid, description: name)
            if !ok {
                let err = NSAlert()
                err.messageText = "保存失败"
                err.informativeText = "无法写入 ~/.claude/状态/session-descriptions.json，查看文件权限。"
                err.alertStyle = .warning
                err.runModal()
                onDone()
                return
            }

            // 2. best-effort 通知 Hub——给 peer 模式的回复标识用（如 "Forge（引擎@P）："）。
            //    失败不回退本地、不弹错误。工具模式会话 Hub 收到会忽略（instance 不在 peer map）。
            if let pid = scanner.sessionPIDMap[sid] {
                let instanceId = "\(client.instancePrefix)\(pid)"
                client.setDescription(instanceId: instanceId, description: name)
            }

            onDone()
        }
    }

    // MARK: - Shared Config Dialog

    /// 通道勾选 + 每通道历史条数对话框。launch 和 resume 共用。
    /// - preselectedChannels: nil → 全勾选（新建场景）；非 nil → 按集合勾选（resume 场景）
    /// - allowSavePreset: true 才显示"保存为预设"按钮
    /// - 返回 nil 表示用户取消；savePreset 只在 allowSavePreset 时有意义
    private func promptChannelConfigDialog(
        title: String,
        hubChannels: [HubClient.ChannelMeta],
        preselectedChannels: Set<String>?,
        allowSavePreset: Bool
    ) -> (subscribe: [String], history: [String: Int], savePreset: Bool)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "订阅：接收该通道的实时消息\n历史：启动时回放的消息条数"
        alert.addButton(withTitle: "以此启动")
        alert.addButton(withTitle: "取消")
        if allowSavePreset {
            alert.addButton(withTitle: "保存为预设...")
        }

        let rowHeight: CGFloat = 28
        let totalHeight = CGFloat(hubChannels.count) * rowHeight + 4
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: totalHeight))

        var checkboxes: [(id: String, sub: NSButton, combo: NSComboBox)] = []

        for (i, ch) in hubChannels.enumerated() {
            let y = totalHeight - CGFloat(i + 1) * rowHeight

            let sub = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            sub.frame = NSRect(x: 0, y: y, width: 20, height: 22)
            let isSelected = preselectedChannels.map { $0.contains(ch.id) } ?? true
            sub.state = isSelected ? .on : .off
            container.addSubview(sub)

            let nameLabel = NSTextField(labelWithString: ch.name)
            nameLabel.frame = NSRect(x: 24, y: y + 2, width: 120, height: 18)
            nameLabel.font = NSFont.systemFont(ofSize: 13)
            container.addSubview(nameLabel)

            let combo = NSComboBox(frame: NSRect(x: 150, y: y, width: 100, height: 24))
            combo.isEditable = true
            combo.completes = false
            combo.numberOfVisibleItems = 6
            combo.addItems(withObjectValues: ["0", "50", "100", "200", "500"])
            combo.stringValue = "100"
            combo.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            container.addSubview(combo)

            let unitLabel = NSTextField(labelWithString: "条")
            unitLabel.frame = NSRect(x: 256, y: y + 2, width: 30, height: 18)
            unitLabel.font = NSFont.systemFont(ofSize: 12)
            unitLabel.textColor = .secondaryLabelColor
            container.addSubview(unitLabel)

            checkboxes.append((id: ch.id, sub: sub, combo: combo))
        }

        alert.accessoryView = container

        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return nil }

        var subscribe: [String] = []
        var history: [String: Int] = [:]
        for (id, sub, combo) in checkboxes {
            if sub.state == .on { subscribe.append(id) }
            let count = Int(combo.stringValue) ?? 100
            if count > 0 { history[id] = max(0, count) }
        }

        let savePreset = allowSavePreset && response == .alertThirdButtonReturn
        return (subscribe, history, savePreset)
    }
}
