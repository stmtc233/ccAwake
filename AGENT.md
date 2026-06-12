# AGENT.md

Guidance for AI coding agents (and new contributors) working on ccAwake.

## What this project is

ccAwake is a native macOS menu-bar utility that keeps a Mac awake while Claude
Code is actively working — even with the lid closed — and turns the display off
when the lid closes. It detects Claude Code activity through Claude's hook
system and toggles macOS sleep behavior via `pmset`.

- Bundle ID: `com.stmtc.ccAwake` · Helper: `com.stmtc.ccAwake.Helper`
- Minimum macOS: 13 · Swift tools version: 6.0
- Menu-bar agent (`LSUIElement`), no Dock icon.

## Architecture

Four SwiftPM targets (one library + three executables):

| Target | Path | Role |
| --- | --- | --- |
| `ccAwakeCore` | `Sources/ccAwakeCore/` | Shared, UI-free logic. No AppKit. |
| `ccAwakeApp` | `Sources/ccAwakeApp/` | AppKit menu-bar app (the controller). |
| `ccAwakeHelper` | `Sources/ccAwakeHelper/` | Privileged XPC daemon that runs `pmset` as root. |
| `ccawake-hook` | `Sources/ccawake-hook/` | CLI invoked by Claude Code hooks. |

### Data flow

1. Claude Code fires lifecycle hooks (`UserPromptSubmit`, `PreToolUse`,
   `PostToolUse` → `touch`; `Notification` → `waiting`; `Stop`, `SessionEnd` →
   `release`). `Notification` fires when Claude pauses for the user (permission
   prompt / error / idle), so the session is marked *waiting* rather than
   released — `keepAwakeWhileWaiting` then decides whether to stay awake.
2. Each hook runs `ccawake-hook <action>`, which reads the hook JSON from stdin,
   parses `session_id`, and updates the session store
   (`~/Library/Application Support/ccAwake/sessions.json`) under a file lock.
3. `ccAwakeApp` polls every 5s (`AppDelegate.evaluate()`): reads the session
   snapshot + AC-power state **off the main thread**, then on `@MainActor`
   decides `shouldPreventSleep` from settings + active sessions + battery policy.
4. To change sleep state it calls the privileged Helper over XPC
   (`HelperManager` → `CCAwakeHelperProtocol` → `ccAwakeHelper` runs `pmset`).
   If the Helper is unavailable, it falls back to an `osascript` admin prompt
   (but never during app termination).

### Key files

- `Sources/ccAwakeApp/AppDelegate.swift` — the controller; 5s evaluate loop,
  menu building, install/uninstall hook actions, termination handling.
- `Sources/ccAwakeApp/HelperManager.swift` — `SMAppService.daemon` registration
  + XPC connection with a once-guard + 3s timeout so calls never hang.
- `Sources/ccAwakeApp/PowerManager.swift` — sleep-state changes via Helper, with
  optional `osascript` fallback (`allowOsascriptFallback`).
- `Sources/ccAwakeApp/SystemReaders.swift` — reads AC power / lid state via
  `pmset`/`ioreg`; sync + off-main (`readIs…`) variants.
- `Sources/ccAwakeCore/ProcessRunner.swift` — shared subprocess runner that
  drains stdout/stderr concurrently to avoid pipe-buffer deadlock.
- `Sources/ccAwakeCore/SessionStore.swift` — session touch/release/snapshot/prune,
  file-locked + atomic.
- `Sources/ccAwakeCore/ClaudeSettingsInstaller.swift` — installs/uninstalls
  ccAwake hooks into `~/.claude/settings.json` (locked, backed up, pruned).
- `Sources/ccAwakeCore/FileLock.swift` / `AtomicJSON.swift` — cross-process
  locking (`flock`) and atomic JSON writes.

## Commands

```sh
swift build                 # debug build
swift test                  # run the ccAwakeCore unit tests
sh scripts/build-app.sh     # assemble .build/ccAwake.app (ad-hoc signed)
open .build/ccAwake.app     # run the assembled app
plutil -lint Resources/en.lproj/*.strings Resources/zh-Hans.lproj/*.strings
```

`build-app.sh` honors `SIGN_IDENTITY` (unset/`-` = ad-hoc; a Developer ID
Application identity = hardened-runtime distribution signing). Under ad-hoc
signing the privileged Helper will **not** register, so keep-awake won't work
locally — that's expected; verify Helper behavior only with a real signed build.

## Conventions

- **Zero third-party dependencies.** Only Apple system frameworks (AppKit,
  ServiceManagement, Foundation, Darwin) are linked. Do not add packages.
- **Async style:** completion handlers returning `Result<Void, Error>`, with
  `@Sendable` closures. No `async/await` in the existing call paths.
- **`@MainActor` isolation:** `AppDelegate`, `PowerManager`, and `HelperManager`
  are `@MainActor`. Subprocess spawns must run off the main thread (use
  `ProcessRunner` on a background queue, hop back via `Task { @MainActor in }`).
- **No force-unwraps / `try!` / `fatalError`.** Handle errors explicitly.
- **Subprocesses:** always go through `ProcessRunner.run` so pipes are drained
  safely. Never `waitUntilExit()` then read an undrained pipe.
- **`ccawake-hook` exits 0 on all errors** by design — a broken store must never
  break Claude Code's workflow. Failures go to stderr only.
- **Cross-process file writes** use `FileLock` + `AtomicJSON`. The settings
  installer locks via a sibling `settings.json.ccAwake-lock` (advisory; it does
  not force Claude Code to cooperate, but keeps the file always-valid).
- **Localization:** user-facing strings go through `L10n` / `NSLocalizedString`,
  with entries in `Resources/{en,zh-Hans}.lproj/Localizable.strings`.

## Testing

Unit tests live in `Tests/ccAwakeCoreTests/` (XCTest) and cover `ccAwakeCore`
only. The AppKit layer, XPC Helper, and `pmset` paths have no automated coverage
— verify those manually by running the signed app. When adding logic to
`ccAwakeCore`, add tests; inject URLs/paths via the testable initializers (e.g.
`ClaudeSessionStore(sessionsURL:lockURL:)`, `ClaudeSettingsInstaller(settingsURL:lockURL:)`).

## CI/CD

- `.github/workflows/ci.yml` — on push/PR: `swift test`, localization lint,
  build the bundle, verify expected files exist.
- `.github/workflows/release.yml` — on `v*` tags: signed build, notarization
  (`notarytool`), stapling, Gatekeeper check, and GitHub Release. See
  [RELEASE.md](RELEASE.md) for required secrets and the full signing flow.

## Gotchas

- The Helper's `SMAuthorizedClients` pins a specific Developer Team OU
  (`5A75X6L3A4`) in `Packaging/Helper-Info.plist`. Forks must update this and the
  bundle identifiers to their own signing identity.
- `CFBundleVersion` must match between `Packaging/Info.plist` and
  `Packaging/Helper-Info.plist`, or `SMAppService` registration gets confused.
- `pmset -a disablesleep` is a system-wide setting; the README warns users not
  to leave a closed, awake MacBook in a bag (thermal risk).
