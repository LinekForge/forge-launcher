# 变更日志

## v0.1.0（2026-04-21）

首次开源发布。

### 功能
- 菜单栏会话管理（380×500 Popover，NSSearchField + NSTableView）
- 会话命名，本地持久化（`session-descriptions.json`，按完整 UUID 索引）
- 实时搜索 + 拼音匹配（CFStringTransform Latin + 首字母）
- ★ 置顶
- 活跃会话检测（PID + `kill -0` + jsonl cross-check）
- 一键窗口聚焦（PID → TTY → Ghostty breadcrumb → AppleScript）
- 竞态 bug 检测 + 修复（Claude Code `--resume` [#8067](https://github.com/anthropics/claude-code/issues/8067)）
- 每 30 秒自动刷新
- launchd 开机自启
- Finder 工具栏支持
- `-p` 一次性调用自动过滤（`entrypoint == "sdk-cli"` 不进列表）

### 可选 Hub 联动
- 📡 通道会话 / @标签 / 通道恢复 / Hub 健康指示
- 没装 Hub 时 📡 相关按钮完全隐藏，零打扰

### 架构
- 11 个 Swift 文件，约 1900 行
- 职责分层：Models / Scanner / Store / DescStore / HubClient / ChannelDialog / HubExtension / PopoverController / AppDelegate / TerminalAdapter
- `swiftc` 直接编译，不需要 Xcode 项目
