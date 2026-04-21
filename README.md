# Forge Launcher

**Claude Code 的菜单栏会话管理器**——常驻菜单栏，一键启动、切换、恢复、搜索、命名会话。

> **安全声明**：Forge Launcher 只在 Claude Code 官方 CLI 和文件接口上做 UI 层。不修改 Claude Code 的源代码、不改动会话 JSONL 文件、不接触 Claude Code 内部状态。启动器自己的数据（名字、置顶）存在独立文件里，和 Claude Code 的数据完全隔离。唯一写入 CC 文件的场景是[竞态修复](#已知问题)（用户手动点击才触发，修复的是 CC 自己写错的 PID 追踪文件）。

* **会话列表** — 按日期分组（今天/昨天/4月20日…），活跃会话绿色标记

* **实时搜索** — 按名字、首条消息、时间过滤，**支持拼音**（输 `yj` 匹配"引擎"）

* **给会话命名** — 右键 →「📝 描述…」，名字存在本地、不依赖 Hub

* **★ 置顶** — 置顶的会话永远在最上面

* **窗口聚焦** — 点击活跃会话，直接跳到它的 Ghostty 终端窗口

* **一键 Resume** — 点击非活跃会话 → `claude --resume`

* **竞态修复** — 检测 Claude Code 的 `--resume` 竞态 bug（[#8067](https://github.com/anthropics/claude-code/issues/8067)），橙色提示 + 一键修复

* **自动刷新** — 每 30 秒后台扫描，绿点实时更新

* **开机自启** — launchd 一次配好

* **Finder 工具栏** — 拖到工具栏，点击在当前目录启动 Claude

### 可选：forge-hub 联动

装了 [forge-hub](https://github.com/LinekForge/forge-hub) 后额外解锁：

* **📡 通道会话** — 启动时订阅 Hub 通道（微信 / Telegram / 飞书 / iMessage）

* **📡 @标签** — 设置路由标签，微信里 `@P` 找对的窗口

* **📡 通道恢复** — 恢复时弹对话框，可调通道订阅和历史条数

* **Hub 健康指示** — 没装 Hub 的用户完全看不到这些按钮（零打扰）；装了但离线会灰掉提示

**Hub 完全可选**——不装也能用所有核心功能（命名、搜索、置顶、窗口聚焦）。

## 安装

### 依赖

* macOS 13.0+（Apple Silicon；x86\_64 需改 `build.sh` 的 target triple）

* Xcode Command Line Tools（`swiftc` + `codesign`）

* Python 3（系统自带）

* [Claude Code](https://claude.ai/code)（`claude` 在 PATH 中）

* 终端：**自动检测**，启动时自动选用系统里在跑的终端

  * 推荐 [Ghostty](https://ghostty.org) — 现代、快、支持精确窗口聚焦

  * Terminal.app 自动兜底（macOS 自带，不用额外装任何东西）

### 编译

```bash
git clone https://github.com/LinekForge/forge-launcher.git
cd forge-launcher
./build.sh
open Forge Launcher.app
```

编译产物 `Forge Launcher.app` 出现在项目根目录。菜单栏右上角出现芙蓉花图标，点击即用。

### 终端切换

菜单栏启动时自动检测终端（Ghostty > Terminal.app），用户无需配置。

装了 [Ghostty](https://ghostty.org) 想切换？三步：

1. **关闭所有正在跑的 Claude Code 实例**（`exit` 或 `⌃D`），避免同一个会话在两个终端各有一个窗口
2. 点菜单栏底栏「退出」
3. 重新打开菜单栏 app

之后新建和恢复会话都在 Ghostty 里。会话数据不受影响——名字、置顶、聊天记录全部保留。

### 开机自启（可选）

把下面的 plist 存到 `~/Library/LaunchAgents/com.forge-launcher.menubar.plist`，然后 `launchctl load` 一次：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.forge-launcher.menubar</string>
    <key>ProgramArguments</key>
    <array>
        <string>open</string>
        <string>-a</string>
        <string>/你的绝对路径/forge-launcher/Forge Launcher.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

## 文件结构

```
menubar/
├── main.swift                 入口（.accessory，不占 Dock）
├── Models.swift               数据结构（Session / DisplayItem / StaleSession）
├── AppDelegate.swift          薄调度层（~230 行，串联所有模块）
├── SessionScanner.swift       活跃检测 + 全量会话扫描
├── SessionStore.swift         置顶持久化
├── SessionDescriptionStore.swift  本地命名持久化（按完整 UUID 索引）
├── TerminalAdapter.swift      终端抽象层（协议 + Ghostty 实现 + TTY breadcrumb）
├── HubClient.swift            Hub HTTP + 文件 I/O（可选，Hub 不在自动降级）
├── ChannelDialog.swift        Hub 相关弹窗 + 流程编排
├── HubExtension.swift         Hub 编排薄层（~52 行）
├── PopoverController.swift    UI（搜索、表格、右键菜单、拼音、Hub 健康）
├── Info.plist                 App 元数据（LSUIElement、文件夹支持）
├── icon.png                   菜单栏图标（18×18 template）
└── AppIcon.icns               App 图标

shared/
└── scan-sessions.py           扫描 ~/.claude/projects/*/*.jsonl，提取首条用户消息

build.sh                       一键编译（quit → swiftc 11 文件 → codesign → 部署脚本）
```

### 会话命名：启动器自己管，Hub 是可选下游

命名存在启动器本地文件 `~/.claude/状态/session-descriptions.json`，按完整 session UUID 索引。启动器是唯一写入者——不和 Hub 抢文件、没有竞争条件。

用户改名时：

1. 启动器写本地文件（同步，权威）
2. 顺便通知 Hub（让微信回复标识带上名字，失败不影响本地）

## 配置文件

| 文件                        | 位置                      | 作用                             |
| ------------------------- | ----------------------- | ------------------------------ |
| session-descriptions.json | \~/.claude/状态/          | 会话名字 + 标签（启动器管理，按 UUID 索引）     |
| session-stars.json        | \~/.claude/状态/          | 置顶列表                           |
| ghostty-ttys/             | \~/.claude/             | TTY → Ghostty terminal ID 桥接文件 |
| scan-sessions.py          | \~/.claude/自动化/scripts/ | 会话扫描脚本（build.sh 自动部署）          |

## 已知问题

* Claude Code 的 `--resume` 有竞态 bug（[#8067](https://github.com/anthropics/claude-code/issues/8067)），偶尔导致 PID 追踪文件记错 session ID。启动器能检测并提示一键修复

* Claude Code 的 `session-id-self-heal` 会往追踪 JSON 追加数据导致格式损坏。启动器做了容错（截取第一个 `{...}` 恢复）

* `claude --resume` 最多显示 50 条历史（Claude Code 限制）

* Ghostty 不暴露 TTY/PID（[ghostty-org/ghostty#10756](https://github.com/ghostty-org/ghostty/issues/10756)），启动器用 breadcrumb 文件桥接

* `swiftc -O` 在 8GB 内存下会卡死，build.sh 不带优化编译

* Claude Code 的 `--resume` 在 compact 后可能丢失最近一轮对话上下文（[#47508](https://github.com/anthropics/claude-code/issues/47508)）——**这是 CC 上游 bug**，无论是否通过启动器 resume 都可能复现。JSONL 文件完整无损，只是 CC 没把 compact 后的新条目加载进 context

## License

MIT — 见 [LICENSE](LICENSE)。
