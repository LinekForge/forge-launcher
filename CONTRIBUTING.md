# Contributing

谢谢想 contribute！

## 本地开发

```bash
git clone https://github.com/LinekForge/forge-launcher.git
cd forge-launcher
./build.sh
open Forge Launcher.app
```

依赖：macOS 13+、Xcode Command Line Tools、Python 3、[Ghostty](https://ghostty.org)、[Claude Code](https://claude.ai/code)。

## 改代码

1. 改 `menubar/` 下的 Swift 文件
2. 跑 `./build.sh` 编译 + 重启
3. build.sh 会先退出旧 app，编完后需要手动 `open Forge Launcher.app`

没有 Xcode 项目——全靠 `swiftc` 直接编译。注意 `swiftc -O` 在 8GB 内存的机器上会卡死，build.sh 故意不带优化。

## 代码风格

- Swift：Apple 标准约定，`os_log` 做诊断日志
- 注释：中文或英文都行
- UI 文字：中文（目标用户是中文 Claude Code 用户）

## Pull Request

- 一个 PR 一个逻辑改动
- 手动测试：rebuild → 打开菜单栏 → 确认改动生效
- PR 描述简洁——改了什么、为什么

## 报 Bug / 提需求

开 GitHub issue，附上：
- macOS 版本
- Claude Code 版本（`claude --version`）
- 期望 vs 实际
- 截图（如果相关）

## License

贡献的代码按 MIT License 许可。
