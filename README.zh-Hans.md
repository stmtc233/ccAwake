# ccAwake

**ccAwake** 是一个 macOS 菜单栏工具，用于在 Claude Code 运行时防止 MacBook 休眠，即使合上盖子也能继续运行。同时，ccAwake 会在检测到合盖后自动关闭屏幕。

[English](README.md)

## 功能

- Claude Code 有活跃会话时，阻止 MacBook 合盖休眠。
- Claude Code 停止、会话超时或手动关闭后，恢复正常休眠。
- 检测到合盖后自动执行熄屏。
- 默认仅在连接电源适配器时启用，也可以在菜单中允许电池供电。
- 可在菜单中开启开机自启动。
- 支持英文和简体中文，语言跟随 macOS 系统偏好。

## 工作原理

Claude Code hooks 会在会话开始、继续、停止或结束时调用 `ccawake-hook`。菜单栏 App 读取会话状态，然后切换 macOS 电源行为：

```sh
/usr/bin/pmset -a disablesleep 1   # 合盖后继续运行
/usr/bin/pmset -a disablesleep 0   # 恢复正常休眠
/usr/bin/pmset displaysleepnow     # 合盖后关闭屏幕
```

需要系统权限的 `pmset` 命令由 `SMAppService` 安装的 privileged helper 通过 XPC 执行。用户只需要首次批准一次。

## 构建

```sh
swift test
sh scripts/build-app.sh
open .build/ccAwake.app
```

Release 自动化说明见 [RELEASE.md](RELEASE.md)。

## Claude Code 集成

打开菜单栏 App，选择 **Install Claude Hooks**。ccAwake 会先备份并合并 `~/.claude/settings.json`：

- `UserPromptSubmit`、`PreToolUse`、`PostToolUse` -> `ccawake-hook touch`
- `Notification` -> `ccawake-hook waiting`（Claude 暂停并等待你的输入）
- `Stop`、`SessionEnd` -> `ccawake-hook release`

当 Claude 暂停等待你的输入或权限确认时，会话会被标记为**等待中**。默认情况下 ccAwake 会在等待时恢复正常休眠；在菜单中开启 **等待用户时保持唤醒** 可保持唤醒直到你回应。

会话状态保存位置：

```text
~/Library/Application Support/ccAwake/sessions.json
```

隔离测试可以指定状态目录：

```sh
CCAWAKE_APP_SUPPORT_DIR=/tmp/ccAwake-test ccawake-hook touch
```

## 安全提示

启用后，合盖防休眠是系统级行为。不要在 ccAwake 保持唤醒时把合盖 MacBook 放进包里。默认策略只允许在连接电源适配器时启用合盖防休眠。

## 致谢

ccAwake 受到以下项目启发：

- [samber/cc-caffeine](https://github.com/samber/cc-caffeine)：Claude Code hooks 驱动的防休眠工作流。
- [daemonphantom/Awayke](https://github.com/daemonphantom/Awayke)：使用 `pmset disablesleep` 处理 MacBook 合盖防休眠的专注方案。
