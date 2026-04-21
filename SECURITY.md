# Security Policy

## 报告漏洞

发现安全问题请**不要**直接 PR 或 public issue。

**报告渠道**：GitHub Security Advisory —— 到 [https://github.com/LinekForge/forge-launcher/security/advisories/new](https://github.com/LinekForge/forge-launcher/security/advisories/new) 提交 private advisory。

尽量 7 天内回复，30 天内提供修复或缓解方案。

如果 GitHub 不可用，请在 issue 里开一个**不含漏洞细节**的 placeholder（如"security concern, please contact me"）并留联系方式。**不要**把漏洞细节发在 public issue 里。

## 安全模型

forge-launcher 是**本地 macOS 菜单栏 app**。它：

- 读取 Claude Code 会话文件（`~/.claude/sessions/*.json`、`~/.claude/projects/*/*.jsonl`）
- 写入会话描述到 `~/.claude/状态/session-descriptions.json`
- 如果装了 [forge-hub](https://github.com/LinekForge/forge-hub)，通过 `localhost:9900` 通信
- 通过 AppleScript 控制 Ghostty 终端
- **不会**发起任何 localhost 以外的网络请求

## 信任边界

- app 信任 `~/.claude/` 目录内容（Claude Code 创建）
- app 信任 `~/.forge-hub/` 目录内容（forge-hub 创建）
- AppleScript 命令中包含用户提供的会话数据——通过转义缓解注入风险，但 AppleScript 本质是 trust-the-input 模型
