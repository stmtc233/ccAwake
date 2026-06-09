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

    private var statusItem: NSStatusItem?
    private var settings: CCAwakeSettings = .default
    private var timer: Timer?
    private var isPreventingSleep = false
    private var pendingSleepTarget: Bool?
    private var lastLidClosed = false
    private var lastSnapshot = SessionSnapshot(allSessions: [:], activeSessions: [:])
    private var lastOnACPower: Bool?
    private var lastStatusMessage = L10n.string("status.inactive")
    private var transientStatusUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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

        powerManager.setSleepDisabled(false) { _ in
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
        do {
            try sessionStore.pruneExpired(timeout: settings.timeout)
            lastSnapshot = try sessionStore.snapshot(timeout: settings.timeout)
        } catch {
            lastStatusMessage = L10n.string("status.sessionReadFailed")
            rebuildMenu()
            return
        }

        lastOnACPower = PowerSourceReader.isOnACPower()
        let onAC = lastOnACPower ?? true
        let wantsClaudeAwake = settings.automationEnabled && lastSnapshot.hasActiveSessions
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
            } else if wantsClaudeAwake {
                lastStatusMessage = L10n.string("status.claudeActive")
            } else if !settings.automationEnabled {
                lastStatusMessage = L10n.string("status.automationPaused")
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

        guard let lidClosed = ClamshellReader.isLidClosed() else { return }
        defer { lastLidClosed = lidClosed }

        guard lidClosed && !lastLidClosed else { return }
        powerManager.displaySleepNow { _ in }
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
        menu.addItem(actionItem(title: L10n.string("menu.turnOffNow"), action: #selector(turnOffNow)))

        menu.addItem(.separator())
        menu.addItem(timeoutMenuItem())
        menu.addItem(batteryPolicyMenuItem())
        menu.addItem(loginItemMenuItem())

        menu.addItem(.separator())
        menu.addItem(actionItem(title: L10n.string("menu.installHooks"), action: #selector(installClaudeHooks)))
        menu.addItem(actionItem(title: L10n.string("menu.uninstallHooks"), action: #selector(uninstallClaudeHooks)))

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
            try ClaudeSettingsInstaller().install(hookExecutablePath: hookPath)
        } catch {
            presentError(title: L10n.string("error.installHooks"), error: error)
        }
    }

    @objc private func uninstallClaudeHooks() {
        do {
            try ClaudeSettingsInstaller().uninstall()
        } catch {
            presentError(title: L10n.string("error.uninstallHooks"), error: error)
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
