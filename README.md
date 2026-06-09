# ccAwake

**ccAwake** is a small macOS menu bar utility that keeps a MacBook awake while Claude Code is working, even when the lid is closed. When the lid closes, ccAwake also turns the display off automatically.

[简体中文](README.zh-Hans.md)

## What It Does

- Prevents lid-close sleep while Claude Code has an active session.
- Restores normal sleep when Claude Code stops, the session expires, or you turn ccAwake off.
- Turns the display off automatically when the MacBook lid is closed.
- Defaults to AC-power-only operation, with an option to allow battery use.
- Can launch automatically at login from the menu bar setting.
- Supports English and Simplified Chinese, selected by macOS language preferences.

## How It Works

Claude Code hooks call `ccawake-hook` when a session starts, continues, stops, or ends. The menu bar app reads that session state and toggles macOS sleep behavior:

```sh
/usr/bin/pmset -a disablesleep 1   # keep running with lid closed
/usr/bin/pmset -a disablesleep 0   # restore normal sleep
/usr/bin/pmset displaysleepnow     # turn display off after lid close
```

The privileged helper uses `SMAppService` and XPC so the app can run the required `pmset` commands after one-time approval.

## Build

```sh
swift test
sh scripts/build-app.sh
open .build/ccAwake.app
```

Release automation is documented in [RELEASE.md](RELEASE.md).

## Claude Code Integration

Open the menu bar app and choose **Install Claude Hooks**. ccAwake backs up and merges `~/.claude/settings.json` with:

- `UserPromptSubmit`, `PreToolUse`, `PostToolUse` -> `ccawake-hook touch`
- `Notification`, `Stop`, `SessionEnd` -> `ccawake-hook release`

Session state is stored at:

```text
~/Library/Application Support/ccAwake/sessions.json
```

For isolated testing:

```sh
CCAWAKE_APP_SUPPORT_DIR=/tmp/ccAwake-test ccawake-hook touch
```

## Safety

Lid-close sleep prevention is system-wide while active. Do not put a closed MacBook in a bag while ccAwake is keeping it awake. The default policy only enables this behavior while connected to a power adapter.

## Acknowledgements

ccAwake was inspired by:

- [samber/cc-caffeine](https://github.com/samber/cc-caffeine), especially its Claude Code hook-driven keep-awake workflow.
- [daemonphantom/Awayke](https://github.com/daemonphantom/Awayke), especially its focused approach to MacBook lid-close sleep prevention with `pmset disablesleep`.
