import Cocoa

/// Hub 编排层——薄 adapter，把 AppDelegate 的调用委托给 HubClient（I/O）和 ChannelDialog（UI）。
///
/// 拆分背景：2026-04-19 为开源准备，把原来 511 行的 HubExtension 按"I/O vs UI"分成三文件。
/// AppDelegate 调用接口保持不变，本层只做 forwarding。
///
/// 2026-04-19 晚重构：rename / resume 流程加入 SessionDescriptionStore——description/tag
/// 的 source of truth 从 Hub 搬回启动器本地。详见 `SessionDescriptionStore.swift` 头注释
/// 和心智模型"启动器 own 名字、Hub 是消费者"小节。
class HubExtension {
    let client: HubClient
    let dialog: ChannelDialog

    /// Hub 是否可达。代理到 client——popover 据此降级通道按钮。
    var isHubOnline: Bool { client.isHubOnline }

    /// 本次 app 运行期间 Hub 是否**曾经**在线过。用于 UI 层决定"是否显示 Hub 离线警告"：
    /// 从未在线 = 这台机器没装 Hub / Hub 从没起来过 → 不打扰用户；
    /// 曾在线现在离线 = Hub 挂了，显示警告给用户
    var isHubEverOnline: Bool { client.isHubEverOnline }

    init(terminal: TerminalAdapter, scanner: SessionScanner, descStore: SessionDescriptionStore) {
        self.client = HubClient(scanner: scanner)
        self.dialog = ChannelDialog(client: self.client, terminal: terminal, scanner: scanner, descStore: descStore)
    }

    // MARK: - Forwarding

    /// 从 Hub /instances 和 identities 读 tag/description 注入 scanner。每次扫描顺带更新 isHubOnline。
    func enrichScanResults() {
        client.enrichScanResults()
    }

    /// 点"📡 通道会话"入口。
    func launchChannel() {
        dialog.launch()
    }

    /// 右键非活跃 session 的"📡 通道恢复"。
    func resumeChannel(_ sid: String) {
        dialog.resume(sid: sid)
    }

    /// 右键活跃 session 的"📡 标签..."。
    func hubNameSession(_ sid: String) {
        dialog.hubName(sid: sid)
    }

    /// 右键任意 session 的"📝 描述..."。
    /// - Parameter scanner: 历史签名的冗余参数（调用方已通过 init 传过 scanner 引用）。
    ///   保留签名以避免 AppDelegate 改动——delete 方向的 refactor 见 README 待做。
    func renameSession(_ sid: String, scanner: SessionScanner, onDone: @escaping () -> Void) {
        dialog.rename(sid: sid, onDone: onDone)
    }

    /// AppDelegate.openSession 直接调用——非通道 resume 时把 desc 写进 next-session.json 让名字跨 resume 存活。
    func writeSessionFile(tag: String, description: String, channels: [String], history: [String: Int]) {
        client.writeSessionFile(tag: tag, description: description, channels: channels, history: history)
    }
}
