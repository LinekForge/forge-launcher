# 变更日志

## v0.1.2（2026-05-19）

### 新功能
- **#7** 可配置默认工作目录——底栏「设置」选择，所有新建/恢复会话使用配置的目录
- **#9** 启动前认证检查（opt-in）——设置里勾选后，启动会话前自动检查 `claude auth status`，未登录弹窗引导

### 架构
- 拆分 `Models.swift` → `Models`（数据类型）+ `Utilities`（共享 helper）+ `AuthGuard`（认证逻辑）
- 14 个 Swift 文件，约 2100 行

### 安全与健壮性
- 所有持久化文件统一 chmod 600
- session ID 拼入 shell 前校验 UUID 格式
- Ghostty 窗口聚焦的 termID 增加 AppleScript 转义
- `SessionDescriptionStore` decode 失败时不覆盖内存数据（防数据丢失）
- 配置文件损坏时 os_log 提示（不再静默 fallback）

### 性能
- Hub 离线时退避 3 个周期（~90s），不再每 30s 白等 curl 超时
- `postToHub` 后台等待进程结束，防孤儿进程

### 代码质量
- 提取 `augmentedEnvironment()` / `isValidUUID()` / `guardAuth()` / `showAuthAlert()` 共享 helper
- shell 路径转义加固（无条件单引号包裹）
- 规范化二进制名和注释

## v0.1.1（2026-05-12）

### Bug 修复
- **#1** 终端动态检测——中途启动 Ghostty 无需重启 Launcher（`DynamicTerminal` wrapper）
- **#2** 删除废弃的 `sessionNames` / `isBold` dead code
- **#5** `SessionDescriptionStore` 每 30s 从磁盘重读，支持外部 hook 写入

### 代码质量（#3 + simplify）
- 提取共享 helper：`hubGet` / `postToHub` / `runAppleScript` / `toLatin` / `instanceIdSuffix` / `channelFlags`
- 删除冗余 `scanner` 参数（`renameSession`）和 `refreshSessions` wrapper
- `descStore.load()` 移到 scan completion（不在 star toggle 时触发）
- `groupDateFormatter` 改 static（避免每行重建）
- 修复 `self!` force-unwrap（crash vector）

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
