import Cocoa

class SessionPopoverController: NSViewController, NSSearchFieldDelegate, NSTextFieldDelegate, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {

    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var warningButton: NSButton!
    private var warningHeight: NSLayoutConstraint!
    private var countLabel: NSTextField!
    private var refreshBtn: NSButton!
    private var channelBtn: NSButton!

    var allSessions: [Session] = []
    var activeSIDs: Set<String> = []
    var sessionNames: [String: String] = [:]
    var starredSIDs: Set<String> = []
    var staleCount = 0
    var hubTags: [String: String] = [:]   // keyed by session ID prefix (8 chars), Hub 兼容 fallback
    var hubDescs: [String: String] = [:]  // keyed by session ID prefix (8 chars), Hub 兼容 fallback
    var sessionDescs: [String: SessionDescription] = [:]  // keyed by FULL sessionId (UUID)——启动器 own 的权威
    var sessionPIDs: [String: Int] = [:]
    var hubOnline: Bool = false           // Hub 当前是否在线（影响 📡 按钮是否可用）
    var hubEverOnline: Bool = false       // 这台机本次运行是否装了/探测到过 Hub（决定是否显示 Hub 离线警告）
    private var displayItems: [DisplayItem] = []

    var onOpen: ((String) -> Void)?
    var onNew: (() -> Void)?
    var onNewChannel: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onHubName: ((String) -> Void)?
    var onResumeChannel: ((String) -> Void)?
    var onStar: ((String) -> Void)?
    var onRepair: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onViewAll: (() -> Void)?

    override func loadView() {
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 500))
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        // Search field
        searchField = NSSearchField()
        searchField.placeholderString = "搜索会话..."
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        // Top buttons
        let newBtn = NSButton(title: "✦ 常规会话", target: self, action: #selector(doNew))
        newBtn.bezelStyle = .rounded; newBtn.controlSize = .small
        channelBtn = NSButton(title: "📡 通道会话", target: self, action: #selector(doNewChannel))
        channelBtn.bezelStyle = .rounded; channelBtn.controlSize = .small
        let topBar = NSStackView(views: [newBtn, channelBtn])
        topBar.orientation = .horizontal; topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topBar)

        // Warning (hidden when no stale)
        warningButton = NSButton(title: "", target: self, action: #selector(doRepair))
        warningButton.isBordered = false
        warningButton.alignment = .left
        warningButton.isHidden = true
        warningButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(warningButton)

        // Table
        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.target = self
        tableView.action = #selector(handleClick)
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.width = 356
        tableView.addTableColumn(col)

        let ctxMenu = NSMenu()
        ctxMenu.delegate = self
        tableView.menu = ctxMenu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Bottom bar
        refreshBtn = makeLink("↻ 刷新", #selector(doRefresh))
        let viewAllBtn = makeLink("查看全部", #selector(doViewAll))
        let quitBtn = makeLink("退出", #selector(doQuit))
        countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomBar = NSStackView(views: [refreshBtn, viewAllBtn, spacer, countLabel, quitBtn])
        bottomBar.orientation = .horizontal; bottomBar.spacing = 12
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bottomBar)

        // Warning height
        warningHeight = warningButton.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            topBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            warningButton.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            warningButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            warningButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            warningHeight,

            scrollView.topAnchor.constraint(equalTo: warningButton.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -4),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            bottomBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        self.view = container
    }

    private func makeLink(_ title: String, _ action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 11)
        btn.contentTintColor = .secondaryLabelColor
        return btn
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        searchField.stringValue = ""
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Data

    func reload() {
        guard isViewLoaded else { return }

        if staleCount > 0 {
            warningButton.isHidden = false
            warningHeight.constant = 22
            warningButton.attributedTitle = NSAttributedString(
                string: "⚠ \(staleCount) 个活跃会话未识别 — 点击修复",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.systemOrange,
                ]
            )
        } else {
            warningButton.isHidden = true
            warningHeight.constant = 0
        }

        // 📡 通道会话按钮降级：
        // - 从未检测到 Hub（没装/没跑）→ **整个隐藏**，不打扰不用 Hub 的用户
        // - Hub 装过但当前离线 → 灰掉 + tooltip 明确说 Hub 挂了
        // - Hub 在线 → 正常可点
        channelBtn?.isHidden = !hubEverOnline && !hubOnline
        channelBtn?.isEnabled = hubOnline
        channelBtn?.toolTip = hubOnline ? nil : "Hub 未在线，通道会话不可用"

        buildDisplayItems(filter: searchField?.stringValue ?? "")
        tableView?.reloadData()
        updateCount()
    }

    private func displayName(for session: Session) -> String {
        var base: String
        let sidPrefix = String(session.sid.prefix(8))

        // description 优先级：启动器本地 store（权威，按完整 sessionId 索引）→ Hub 兼容 fallback → first-msg
        if let stored = sessionDescs[session.sid]?.description, !stored.isEmpty {
            base = "【\(stored)】"
        } else if let desc = hubDescs[sidPrefix] {
            base = "【\(desc)】"
        } else {
            base = session.display
        }

        // tag 优先级：本地 store → Hub 兼容 fallback
        if let storedTag = sessionDescs[session.sid]?.tag, !storedTag.isEmpty {
            base += " @\(storedTag)"
        } else if let hubTag = hubTags[sidPrefix] {
            base += " @\(hubTag)"
        }

        return base
    }

    private func updateCount() {
        let sessionCount = displayItems.filter {
            if case .session = $0 { return true }; return false
        }.count
        let query = searchField?.stringValue ?? ""
        let countText: String
        if query.isEmpty {
            countText = "\(allSessions.count) 条会话"
        } else {
            countText = "匹配 \(sessionCount) / \(allSessions.count)"
        }
        // Hub 离线警告**只在这台机曾经用过 Hub** 才显示——不打扰从未装 Hub 的用户。
        // 本次 app 运行期间 Hub 从未在线过 = 没装/没跑 Hub，视作"不用 Hub"的场景
        let showHubOfflineWarning = hubEverOnline && !hubOnline
        countLabel?.stringValue = showHubOfflineWarning ? "⚠ Hub 离线 · \(countText)" : countText
        countLabel?.textColor = showHubOfflineWarning ? .systemOrange : .tertiaryLabelColor
    }

    /// 把中文转成 "全拼音 + 首字母拼接" 形式，用于搜索 fallback。
    /// "Forge引擎" → "forge yin qing fyq"——用户打 "yj" 或 "yinjing" 都能命中。
    /// 纯英文/数字原样包含（转换对拉丁字符是 noop），不影响英文搜索。
    private func searchablePinyin(_ s: String) -> String {
        let mutable = NSMutableString(string: s)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let latin = (mutable as String).lowercased()
        let initials = latin
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap { $0.first }
            .map(String.init)
            .joined()
        return latin + " " + initials
    }

    private func buildDisplayItems(filter: String) {
        displayItems = []

        let list: [Session]
        if filter.isEmpty {
            list = allSessions
        } else {
            let q = filter.lowercased()
            list = allSessions.filter { s in
                // 搜的是实际显示给用户看的名字（含 Hub description / custom name / first-msg 优先级），
                // 而不是只看 sessionNames——4/2 重构后 sessionNames 永远为空，用户给会话写的
                // description 存在 hubDescs 里，必须走 displayName 才能命中。
                let displayed = displayName(for: s).lowercased()
                let firstMsg = s.display.lowercased()
                if displayed.contains(q) || firstMsg.contains(q) || s.time.contains(q) {
                    return true
                }
                // 拼音 fallback：中文内容不需要用户切到中文输入法
                return searchablePinyin(displayed).contains(q) || searchablePinyin(firstMsg).contains(q)
            }
        }

        // Starred sessions first
        let starred = list.filter { starredSIDs.contains($0.sid) }
        let rest = list.filter { !starredSIDs.contains($0.sid) }

        if !starred.isEmpty {
            displayItems.append(.header("★ 置顶"))
            for session in starred {
                let isActive = activeSIDs.contains(session.sid)
                let name = displayName(for: session)
                let isBold = sessionNames[session.sid] != nil
                displayItems.append(.session(session, isActive: isActive, displayName: name, isBold: isBold))
            }
        }

        var currentGroup = ""
        for session in rest {
            let group = groupLabel(for: session.timestamp)
            if group != currentGroup {
                currentGroup = group
                displayItems.append(.header(group))
            }
            let isActive = activeSIDs.contains(session.sid)
            let name = displayName(for: session)
            let isBold = sessionNames[session.sid] != nil
            displayItems.append(.session(session, isActive: isActive, displayName: name, isBold: isBold))
        }
    }

    private func groupLabel(for timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        buildDisplayItems(filter: searchField.stringValue)
        tableView.reloadData()
        updateCount()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            for item in displayItems {
                if case .session(let s, _, _, _) = item { onOpen?(s.sid); return true }
            }
            return true
        }
        if commandSelector == #selector(moveDown(_:)) {
            view.window?.makeFirstResponder(tableView)
            for i in 0..<displayItems.count {
                if case .session = displayItems[i] {
                    tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                    tableView.scrollRowToVisible(i)
                    break
                }
            }
            return true
        }
        return false
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { displayItems.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = displayItems[row]
        switch item {
        case .header(let title):
            let cell = NSTextField(labelWithString: title)
            cell.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            cell.textColor = .secondaryLabelColor
            return cell

        case .session(let session, let isActive, let name, let isBold):
            let prefix = isActive ? "● " : "   "
            let text = "\(prefix)\(session.time)  \(name)"
            let cell = NSTextField(labelWithString: text)
            cell.lineBreakMode = .byTruncatingTail

            if isActive && isBold {
                cell.font = NSFont.systemFont(ofSize: 13, weight: .medium)
                cell.textColor = .systemGreen
            } else if isActive {
                cell.font = NSFont.systemFont(ofSize: 13)
                cell.textColor = .systemGreen
            } else if isBold {
                cell.font = NSFont.systemFont(ofSize: 13, weight: .medium)
                cell.textColor = .labelColor
            } else {
                cell.font = NSFont.systemFont(ofSize: 13)
                cell.textColor = .labelColor
            }

            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch displayItems[row] {
        case .header: return 22
        case .session: return 26
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = displayItems[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = displayItems[row] { return true }
        return false
    }

    // MARK: - Click

    @objc func handleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < displayItems.count else { return }
        if case .session(let session, _, _, _) = displayItems[row] {
            onOpen?(session.sid)
        }
    }

    // MARK: - Context Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < displayItems.count else { return }
        if case .session(let session, _, _, _) = displayItems[row] {
            let renameItem = NSMenuItem(title: "📝 描述...", action: #selector(doRename(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = session.sid
            menu.addItem(renameItem)

            // 📡 标签（活跃会话） — Hub 在线才有意义。从未装过 Hub 的用户隐藏此项减少噪音
            if activeSIDs.contains(session.sid) && (hubEverOnline || hubOnline) {
                let hubItem = NSMenuItem(
                    title: hubOnline ? "📡 标签..." : "📡 标签... (Hub 离线)",
                    action: hubOnline ? #selector(doHubName(_:)) : nil,
                    keyEquivalent: ""
                )
                hubItem.target = self
                hubItem.representedObject = session.sid
                menu.addItem(hubItem)
            }

            let isStarred = starredSIDs.contains(session.sid)
            let starTitle = isStarred ? "☆ 取消置顶" : "★ 置顶"
            let starItem = NSMenuItem(title: starTitle, action: #selector(doStar(_:)), keyEquivalent: "")
            starItem.target = self
            starItem.representedObject = session.sid
            menu.addItem(starItem)

            // 📡 通道恢复（非活跃会话） — 同上，从未装过 Hub 的用户隐藏
            if !activeSIDs.contains(session.sid) && (hubEverOnline || hubOnline) {
                let resumeChItem = NSMenuItem(
                    title: hubOnline ? "📡 通道恢复" : "📡 通道恢复 (Hub 离线)",
                    action: hubOnline ? #selector(doResumeChannel(_:)) : nil,
                    keyEquivalent: ""
                )
                resumeChItem.target = self
                resumeChItem.representedObject = session.sid
                menu.addItem(resumeChItem)
            }

            menu.addItem(NSMenuItem.separator())

            let copyItem = NSMenuItem(title: "复制 Session ID", action: #selector(doCopyID(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = session.sid
            menu.addItem(copyItem)
        }
    }

    @objc func doResumeChannel(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        onResumeChannel?(sid)
    }

    @objc func doHubName(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        onHubName?(sid)
    }

    @objc func doRename(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        onRename?(sid)
    }

    @objc func doStar(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        onStar?(sid)
    }

    @objc func doCopyID(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sid, forType: .string)
    }

    // MARK: - Actions

    @objc func doNew() { onNew?() }
    @objc func doNewChannel() { onNewChannel?() }
    @objc func doRepair() { onRepair?() }
    @objc func doRefresh() {
        refreshBtn.title = "刷新中..."
        refreshBtn.isEnabled = false
        onRefresh?()
    }

    func refreshDone() {
        guard refreshBtn != nil else { return }
        refreshBtn.title = "↻ 刷新"
        refreshBtn.isEnabled = true
    }
    @objc func doViewAll() { onViewAll?() }
    @objc func doQuit() { onQuit?() }
}
