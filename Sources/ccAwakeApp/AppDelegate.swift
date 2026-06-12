import AppKit
import Foundation
import ccAwakeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = CCAwakePaths()
    private let helper = HelperManager.shared
    private let loginItem = LoginItemManager.shared
    private let powerManager = PowerManager()
    private lazy var sessionStore = ClaudeSessionStore(paths: paths)
    private lazy var settingsStore = SettingsStore(paths: paths)
    private let hookInstaller = ClaudeSettingsInstaller()

    private var statusItem: NSStatusItem?
    private var settings: CCAwakeSettings = .default
    private var timer: Timer?
    private var isPreventingSleep = false
    private var pendingSleepTarget: Bool?
    private var lastLidClosed = false
    private var lastSnapshot = SessionSnapshot(allSessions: [:], activeSessions: [:])
    private var lastOnACPower: Bool?
    private var hookStatus: ClaudeSettingsInstaller.InstallationStatus = .notInstalled
    private var lastStatusMessage = L10n.string("status.inactive")
    private var transientStatusUntil: Date?
    private var isEvaluating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try paths.ensureApplicationSupportDirectory()
            settings = try settingsStore.load()
        } catch {
            presentError(title: L10n.string("error.loadSettings"), error: error)
        }

        helper.register()
        setupStatusItem()
        rebuildMenu()

        if helper.isUsable {
            powerManager.setSleepDisabled(false) { _ in }
        }

        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluate()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()

        guard isPreventingSleep || pendingSleepTarget == true else {
            return .terminateNow
        }

        // Only the privileged helper can clear the sleep state silently. If it
        // is unavailable we terminate immediately rather than popping an
        // osascript admin-password dialog during shutdown.
        guard helper.isUsable else {
            return .terminateNow
        }

        powerManager.setSleepDisabled(false, allowOsascriptFallback: false) { _ in
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.title = "ccA"
        item.button?.toolTip = L10n.string("app.name")
    }

    private func evaluate() {
        // Async reads (session store + pmset) can outlast the 5s tick interval.
        // Guard against overlapping evaluations stomping each other's state.
        guard !isEvaluating else { return }
        isEvaluating = true

        let store = sessionStore
        let timeout = settings.timeout
        let installer = hookInstaller

        // Read the session store and AC power state off the main thread so the
        // 5s timer never blocks the UI on subprocess spawns.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshotResult: Result<SessionSnapshot, Error>
            do {
                try store.pruneExpired(timeout: timeout)
                snapshotResult = .success(try store.snapshot(timeout: timeout))
            } catch {
                snapshotResult = .failure(error)
            }
            let onAC = PowerSourceReader.isOnACPower()
            let hookStatus = installer.installationStatus()

            Task { @MainActor in
                self?.hookStatus = hookStatus
                self?.applyEvaluation(snapshotResult: snapshotResult, onACPower: onAC)
            }
        }
    }

    private func applyEvaluation(snapshotResult: Result<SessionSnapshot, Error>, onACPower: Bool?) {
        defer { isEvaluating = false }

        switch snapshotResult {
        case .failure:
            lastStatusMessage = L10n.string("status.sessionReadFailed")
            rebuildMenu()
            return
        case .success(let snapshot):
            lastSnapshot = snapshot
        }

        lastOnACPower = onACPower
        let onAC = onACPower ?? true
        // Working sessions always justify staying awake. Sessions paused for the
        // user count only when the user opted into keeping awake while waiting;
        // otherwise pausing for input restores normal sleep.
        let hasWorking = lastSnapshot.hasWorkingSessions
        let hasWaiting = lastSnapshot.hasWaitingSessions
        let wantsClaudeAwake = settings.automationEnabled
            && (hasWorking || (hasWaiting && settings.keepAwakeWhileWaiting))
        let wantsAwake = settings.manualKeepAwake || wantsClaudeAwake
        let policyAllowsAwake = settings.allowOnBattery || onAC
        let shouldPreventSleep = wantsAwake && policyAllowsAwake

        if transientStatusUntil.map({ Date() >= $0 }) ?? false {
            transientStatusUntil = nil
        }

        if transientStatusUntil == nil {
            if wantsAwake && !policyAllowsAwake {
                lastStatusMessage = L10n.string("status.blockedOnBattery")
            } else if settings.manualKeepAwake {
                lastStatusMessage = L10n.string("status.manualKeepAwake")
            } else if !settings.automationEnabled {
                lastStatusMessage = L10n.string("status.automationPaused")
            } else if hasWorking {
                lastStatusMessage = L10n.string("status.claudeActive")
            } else if hasWaiting {
                // Paused for the user; show whether we kept awake or let it sleep.
                lastStatusMessage = settings.keepAwakeWhileWaiting
                    ? L10n.string("status.waitingKeepAwake")
                    : L10n.string("status.waitingSleep")
            } else {
                lastStatusMessage = L10n.string("status.inactive")
            }
        }

        applySleepStateIfNeeded(shouldPreventSleep)
        handleClamshellDisplaySleepIfNeeded(shouldPreventSleep)
        rebuildMenu()
    }

    private func applySleepStateIfNeeded(_ target: Bool) {
        guard target != isPreventingSleep else { return }
        guard pendingSleepTarget != target else { return }

        pendingSleepTarget = target
        powerManager.setSleepDisabled(target) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingSleepTarget = nil
                switch result {
                case .success:
                    self.isPreventingSleep = target
                case .failure(let error):
                    self.isPreventingSleep = false
                    self.presentError(title: L10n.string("error.changeSleepState"), error: error)
                }
                self.rebuildMenu()
            }
        }
    }

    private func handleClamshellDisplaySleepIfNeeded(_ shouldPreventSleep: Bool) {
        guard shouldPreventSleep else {
            lastLidClosed = false
            return
        }

        // Read lid state off the main thread; do edge detection back on main.
        ClamshellReader.readIsLidClosed { [weak self] lidClosed in
            Task { @MainActor in
                guard let self, let lidClosed else { return }
                let wasClosed = self.lastLidClosed
                self.lastLidClosed = lidClosed

                guard lidClosed && !wasClosed else { return }
                self.powerManager.displaySleepNow { result in
                    if case .failure(let error) = result {
                        NSLog("ccAwake: displaySleepNow failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: L10n.format("menu.status", lastStatusMessage), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let active = NSMenuItem(
            title: isPreventingSleep ? L10n.string("menu.sleepDisabled") : L10n.string("menu.sleepNormal"),
            action: nil,
            keyEquivalent: ""
        )
        active.isEnabled = false
        menu.addItem(active)

        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: settings.automationEnabled ? L10n.string("menu.pauseAutomation") : L10n.string("menu.resumeAutomation"),
            action: #selector(toggleAutomation)
        ))
        menu.addItem(actionItem(
            title: settings.manualKeepAwake ? L10n.string("menu.manualOn") : L10n.string("menu.manualOff"),
            action: #selector(toggleManualKeepAwake)
        ))
        menu.addItem(actionItem(
            title: settings.keepAwakeWhileWaiting ? L10n.string("menu.keepAwakeWhileWaitingOn") : L10n.string("menu.keepAwakeWhileWaitingOff"),
            action: #selector(toggleKeepAwakeWhileWaiting)
        ))
        menu.addItem(actionItem(title: L10n.string("menu.turnOffNow"), action: #selector(turnOffNow)))

        menu.addItem(.separator())
        menu.addItem(timeoutMenuItem())
        menu.addItem(batteryPolicyMenuItem())
        menu.addItem(loginItemMenuItem())

        menu.addItem(.separator())
        for item in hookMenuItems() {
            menu.addItem(item)
        }

        if let helperItem = helperStatusMenuItem() {
            menu.addItem(.separator())
            menu.addItem(helperItem)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(title: L10n.string("menu.quit"), action: #selector(quit), keyEquivalent: "q"))

        statusItem?.button?.title = isPreventingSleep ? "ccA*" : "ccA"
        statusItem?.button?.toolTip = L10n.format("tooltip.status", lastStatusMessage)
        statusItem?.menu = menu
    }

    private func timeoutMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.format("menu.timeout", L10n.timeout(settings.timeout)), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for minutes in [15, 30, 60] {
            let child = actionItem(title: L10n.format("timeout.minutes", minutes), action: #selector(selectTimeout(_:)))
            child.representedObject = SessionTimeout.minutes(minutes)
            child.state = settings.timeout == .minutes(minutes) ? .on : .off
            submenu.addItem(child)
        }

        let never = actionItem(title: L10n.string("timeout.never"), action: #selector(selectTimeout(_:)))
        never.representedObject = SessionTimeout.never
        never.state = settings.timeout == .never ? .on : .off
        submenu.addItem(never)

        submenu.addItem(.separator())
        submenu.addItem(actionItem(title: L10n.string("menu.customTimeout"), action: #selector(customTimeout)))

        item.submenu = submenu
        return item
    }

    private func batteryPolicyMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: settings.allowOnBattery ? L10n.string("menu.powerPolicyBattery") : L10n.string("menu.powerPolicyAC"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()

        let acOnly = actionItem(title: L10n.string("menu.onlyPowerAdapter"), action: #selector(selectBatteryPolicy(_:)))
        acOnly.representedObject = false
        acOnly.state = settings.allowOnBattery ? .off : .on
        submenu.addItem(acOnly)

        let batteryAllowed = actionItem(title: L10n.string("menu.allowBattery"), action: #selector(selectBatteryPolicy(_:)))
        batteryAllowed.representedObject = true
        batteryAllowed.state = settings.allowOnBattery ? .on : .off
        submenu.addItem(batteryAllowed)

        item.submenu = submenu
        return item
    }

    private func loginItemMenuItem() -> NSMenuItem {
        let title: String
        switch loginItem.state {
        case .enabled:
            title = L10n.string("menu.launchAtLoginOn")
        case .awaitingApproval:
            title = L10n.string("menu.launchAtLoginApproval")
        case .notRegistered, .notFound:
            title = L10n.string("menu.launchAtLoginOff")
        }

        let item = actionItem(title: title, action: #selector(toggleLaunchAtLogin))
        item.state = loginItem.isEnabled ? .on : .off
        return item
    }

    /// Build the Claude hooks section, adapting to whether ccAwake's hooks are
    /// already installed. A non-clickable status line plus only the relevant
    /// action(s): install when absent, re-install + uninstall when present, and
    /// a repair-oriented re-install when partially installed.
    private func hookMenuItems() -> [NSMenuItem] {
        let statusKey: String
        switch hookStatus {
        case .notInstalled:
            statusKey = "menu.hooksStatusNotInstalled"
        case .partial:
            statusKey = "menu.hooksStatusPartial"
        case .installed:
            statusKey = "menu.hooksStatusInstalled"
        }

        let statusLine = NSMenuItem(title: L10n.string(statusKey), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        var items: [NSMenuItem] = [statusLine]

        switch hookStatus {
        case .notInstalled:
            items.append(actionItem(title: L10n.string("menu.installHooks"), action: #selector(installClaudeHooks)))
        case .partial:
            items.append(actionItem(title: L10n.string("menu.repairHooks"), action: #selector(installClaudeHooks)))
            items.append(actionItem(title: L10n.string("menu.uninstallHooks"), action: #selector(uninstallClaudeHooks)))
        case .installed:
            items.append(actionItem(title: L10n.string("menu.reinstallHooks"), action: #selector(installClaudeHooks)))
            items.append(actionItem(title: L10n.string("menu.uninstallHooks"), action: #selector(uninstallClaudeHooks)))
        }

        return items
    }

    private func helperStatusMenuItem() -> NSMenuItem? {
        switch helper.state {
        case .enabled:
            return nil
        case .awaitingApproval:
            return actionItem(title: L10n.string("menu.approveHelper"), action: #selector(approveHelper))
        case .notRegistered:
            let item = NSMenuItem(title: L10n.string("menu.helperInstalling"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .notFound:
            let item = NSMenuItem(title: L10n.string("menu.helperNotFound"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
    }

    private func actionItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func toggleAutomation() {
        transientStatusUntil = nil
        settings.automationEnabled.toggle()
        saveSettingsAndEvaluate()
    }

    @objc private func toggleManualKeepAwake() {
        transientStatusUntil = nil
        settings.manualKeepAwake.toggle()
        saveSettingsAndEvaluate()
    }

    @objc private func toggleKeepAwakeWhileWaiting() {
        transientStatusUntil = nil
        settings.keepAwakeWhileWaiting.toggle()
        saveSettingsAndEvaluate()
    }

    @objc private func turnOffNow() {
        let wasPreventingSleep = isPreventingSleep || pendingSleepTarget == true
        settings.manualKeepAwake = false
        settings.automationEnabled = false
        transientStatusUntil = Date().addingTimeInterval(8)
        lastStatusMessage = wasPreventingSleep
            ? L10n.string("status.restoringSleep")
            : L10n.string("status.alreadyNormal")
        do {
            try settingsStore.save(settings)
        } catch {
            presentError(title: L10n.string("error.saveSettings"), error: error)
        }
        rebuildMenu()
        applySleepStateIfNeeded(false)
    }

    @objc private func selectTimeout(_ sender: NSMenuItem) {
        guard let timeout = sender.representedObject as? SessionTimeout else { return }
        settings.timeout = timeout
        saveSettingsAndEvaluate()
    }

    @objc private func customTimeout() {
        let alert = NSAlert()
        alert.messageText = L10n.string("alert.customTimeout.title")
        alert.informativeText = L10n.string("alert.customTimeout.message")
        alert.addButton(withTitle: L10n.string("button.save"))
        alert.addButton(withTitle: L10n.string("button.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.stringValue = "30"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 30
        settings.timeout = value <= 0 ? .never : .minutes(value)
        saveSettingsAndEvaluate()
    }

    @objc private func selectBatteryPolicy(_ sender: NSMenuItem) {
        guard let allowOnBattery = sender.representedObject as? Bool else { return }
        settings.allowOnBattery = allowOnBattery
        saveSettingsAndEvaluate()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try loginItem.toggle()
            rebuildMenu()
        } catch {
            presentError(title: L10n.string("error.launchAtLogin"), error: error)
        }
    }

    @objc private func installClaudeHooks() {
        do {
            let hookPath = try hookExecutablePath()
            try hookInstaller.install(hookExecutablePath: hookPath)
            refreshHookStatus()
        } catch {
            presentError(title: L10n.string("error.installHooks"), error: error)
        }
    }

    @objc private func uninstallClaudeHooks() {
        do {
            try hookInstaller.uninstall()
            refreshHookStatus()
        } catch {
            presentError(title: L10n.string("error.uninstallHooks"), error: error)
        }
    }

    /// Re-read installation status off the main thread after an install/uninstall
    /// so the menu reflects the change without waiting for the next 5s tick.
    private func refreshHookStatus() {
        let installer = hookInstaller
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = installer.installationStatus()
            Task { @MainActor in
                self?.hookStatus = status
                self?.rebuildMenu()
            }
        }
    }

    @objc private func approveHelper() {
        helper.revealInSystemSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func saveSettingsAndEvaluate() {
        do {
            try settingsStore.save(settings)
        } catch {
            presentError(title: L10n.string("error.saveSettings"), error: error)
        }
        evaluate()
    }

    private func hookExecutablePath() throws -> String {
        let fileManager = FileManager.default
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let sibling = executableDirectory.appendingPathComponent("ccawake-hook")
            if fileManager.isExecutableFile(atPath: sibling.path) {
                return sibling.path
            }
        }

        let commonInstallPath = "/usr/local/bin/ccawake-hook"
        if fileManager.isExecutableFile(atPath: commonInstallPath) {
            return commonInstallPath
        }

        throw NSError(
            domain: "com.stmtc.ccAwake",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: L10n.string("error.hookNotFound")
            ]
        )
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("button.ok"))
        alert.runModal()
    }
}
