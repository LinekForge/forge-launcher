import Foundation

/// Hub 编排层——薄 adapter，把 AppDelegate 的调用委托给 HubClient（I/O）和 ChannelDialog（UI）。
/// AppDelegate 调用接口保持不变，本层只做 forwarding。
final class HubExtension {
    let client: HubClient
    let dialog: ChannelDialog

    /// Hub 是否可达。代理到 client——popover 据此降级通道按钮。
    var isHubOnline: Bool { client.isHubOnline }

    /// 本次 app 运行期间 Hub 是否**曾经**在线过。用于 UI 层决定"是否显示 Hub 离线警告"：
    /// 从未在线 = 这台机器没装 Hub / Hub 从没起来过 → 不打扰用户；
    /// 曾在线现在离线 = Hub 挂了，显示警告给用户
    var isHubEverOnline: Bool { client.isHubEverOnline }

    init(terminal: TerminalAdapter, scanner: SessionScanner, descStore: SessionDescriptionStore, config: ConfigStore) {
        self.client = HubClient(scanner: scanner)
        self.dialog = ChannelDialog(client: self.client, terminal: terminal, scanner: scanner, descStore: descStore, config: config)
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
    func renameSession(_ sid: String, onDone: @escaping () -> Void) {
        dialog.rename(sid: sid, onDone: onDone)
    }

    /// AppDelegate.openSession 直接调用——非通道 resume 时把 desc 写进 next-session.json 让名字跨 resume 存活。
    func writeSessionFile(tag: String, description: String, channels: [String], history: [String: Int]) {
        client.writeSessionFile(tag: tag, description: description, channels: channels, history: history)
    }
}
