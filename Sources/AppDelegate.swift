import AppKit

/// Set by the C reconfiguration callback, which cannot capture context.
private var onReconfigure: ((CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void)?

/// Which monitor a menu item acts on. The id tells identical monitors apart; the key survives a reconnect.
class DisplayRef: NSObject {
    let id: CGDirectDisplayID
    let key: String
    init(_ display: ExternalDisplay) {
        id = display.id
        key = display.key
    }

    var display: ExternalDisplay? { Displays.find(id: id, key: key) }
}

final class ModeChoice: DisplayRef {
    let spec: ModeSpec
    init(_ display: ExternalDisplay, spec: ModeSpec) {
        self.spec = spec
        super.init(display)
    }
}

final class ColorChoice: DisplayRef {
    let target: WhiteTarget?
    let profile: URL?
    init(_ display: ExternalDisplay, target: WhiteTarget? = nil, profile: URL? = nil) {
        self.target = target
        self.profile = profile
        super.init(display)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var pendingRestore: DispatchWorkItem?
    private var pendingProbe: DispatchWorkItem?
    private var pendingDimming: DispatchWorkItem?
    private var dimmingDeadline = DispatchTime.now()
    private var probeDeadline = DispatchTime.now()
    private var autoRestores = 0
    private var unlocking = Set<String>()
    private var lastConnectOrWake = Date()
    private var lastOwnModeChange = Date.distantPast
    private let keys = MediaKeys()
    private var permissionTimer: Timer?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.migrateFromPrototype()
        // The prototype build would fight this one over display modes and gamma tables.
        NSRunningApplication.runningApplications(withBundleIdentifier: "local.smoothdisplay").forEach { $0.terminate() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "SmoothDisplay")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        menu.delegate = self
        statusItem.menu = menu

        keys.onBrightness = { [weak self] up, fine in self?.brightnessKey(up: up, fine: fine) ?? false }
        if !Preferences.welcomed {
            Preferences.welcomed = true
            welcome()
        }
        if !MediaKeys.isAllowed, Preferences.brightnessKeys, !UserDefaults.standard.bool(forKey: "accessibilityPrompted") {
            UserDefaults.standard.set(true, forKey: "accessibilityPrompted")
            MediaKeys.requestPermission()
        }
        startBrightnessKeys()

        onReconfigure = { [weak self] id, flags in self?.displayReconfigured(id, flags) }
        CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { onReconfigure?(id, flags) }
        }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // Display sleep without system sleep also makes some monitors re-link and drop to 1×.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        // A new profile reloads the gamma table and wipes software dimming.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(profilesChanged),
            name: Notification.Name(kColorSyncDisplayDeviceProfilesNotification.takeUnretainedValue() as String), object: nil)

        scheduleRestore(after: 1)
        // Probe after the restored mode has settled: a link retraining mid-probe looks like a monitor ignoring DDC.
        scheduleProbe(after: 2.5)

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { Updates.checkIfDue() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Updates.checkIfDue() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SoftwareDimming.restoreAll()
    }

    /// A menu bar app has no window; tell first-time users where it lives.
    private func welcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("SmoothDisplay is in the menu bar")
        alert.informativeText = L("Click the display icon in the menu bar to switch your external monitor to a Retina (HiDPI) mode, adjust its brightness and pick a color profile.\n\nTo control the monitor with the brightness keys, allow SmoothDisplay in System Settings › Privacy & Security › Accessibility when macOS asks.")
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    // MARK: Keeping the chosen mode

    @objc private func didWake() {
        lastConnectOrWake = Date()
        autoRestores = 0
        Brightness.shared.reset() // the DDC service objects may have been recreated
        scheduleRestore(after: 3)
        scheduleDimming(after: 3)
    }

    private func displayReconfigured(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
        if flags.contains(.addFlag) || flags.contains(.enabledFlag) {
            lastConnectOrWake = Date()
            autoRestores = 0
            Brightness.shared.reset()
            scheduleRestore(after: 2)
            scheduleProbe(after: 4)
        } else if flags.contains(.removeFlag) || flags.contains(.disabledFlag) {
            // With identical monitors the remaining one may take over the other's key.
            scheduleProbe(after: 1)
        } else if flags.contains(.setModeFlag) {
            scheduleDimming(after: 0.6) // a mode change reloads the gamma table
            modeChangedElsewhere(id)
        }
    }

    /// A mode change SmoothDisplay did not make. A drop to 1× shortly after a connect or wake is macOS falling
    /// back (the reason Keep Mode exists), so it is undone, a few times at most so nothing can ping-pong. Any other
    /// change, later, is the user's choice (e.g. in System Settings) and is remembered instead of being undone.
    private func modeChangedElsewhere(_ id: CGDirectDisplayID) {
        guard Date().timeIntervalSince(lastOwnModeChange) > 3,
              let display = Displays.external().first(where: { $0.id == id }),
              let mode = display.currentMode,
              let remembered = Preferences.desiredMode(for: display), remembered != mode.spec else { return }
        let sinceConnect = Date().timeIntervalSince(lastConnectOrWake)
        if !mode.spec.isHiDPI && remembered.isHiDPI && sinceConnect < 20 {
            guard Preferences.keepModes, autoRestores < 3 else { return }
            autoRestores += 1
            DebugLog.write("\(display.name): dropped to \(mode.spec.size), restoring \(remembered.size)")
            scheduleRestore(after: 2)
        } else if sinceConnect > 8 {
            Preferences.setDesiredMode(mode.spec, for: display)
            DebugLog.write("\(display.name): \(mode.spec.size) was chosen outside SmoothDisplay, remembering it")
        }
    }

    /// Coalesced, so a burst of display callbacks resets the gamma tables once. A later run that is already
    /// planned (e.g. after wake, once ColorSync has reloaded) is kept rather than replaced by an earlier one.
    private func scheduleDimming(after seconds: Double) {
        let deadline = DispatchTime.now() + seconds
        if let pending = pendingDimming, !pending.isCancelled, dimmingDeadline >= deadline { return }
        pendingDimming?.cancel()
        let work = DispatchWorkItem { SoftwareDimming.reapply() }
        pendingDimming = work
        dimmingDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
    }

    /// Same coalescing as scheduleDimming: a probe planned for after the mode settles is never pulled earlier.
    private func scheduleProbe(after seconds: Double) {
        let deadline = DispatchTime.now() + seconds
        if let pending = pendingProbe, !pending.isCancelled, probeDeadline >= deadline { return }
        pendingProbe?.cancel()
        let work = DispatchWorkItem { Displays.external().forEach { Brightness.shared.probe($0) } }
        pendingProbe = work
        probeDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
    }

    @objc private func profilesChanged() {
        scheduleDimming(after: 0.6)
    }

    private func scheduleRestore(after seconds: Double) {
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreModes() }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// macOS often falls back to the blurry 1× mode when a monitor reconnects; put the chosen mode back.
    private func restoreModes() {
        guard Preferences.keepModes else { return }
        for display in Displays.external() {
            guard let wanted = Preferences.desiredMode(for: display),
                  display.currentMode?.spec != wanted,
                  let mode = display.mode(matching: wanted) else { continue }
            lastOwnModeChange = Date()
            Displays.apply(mode, to: display.id)
        }
    }

    // MARK: Brightness

    private func startBrightnessKeys() {
        guard Preferences.brightnessKeys, !keys.isRunning else { return }
        if MediaKeys.isAllowed, keys.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            // Pick up the permission as soon as it is granted in System Settings (and retry a failed tap).
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, Preferences.brightnessKeys else { return }
                if MediaKeys.isAllowed { self.startBrightnessKeys() }
            }
        }
    }

    /// Brightness key pressed: adjust the external monitor under the pointer, leave the built-in screen to macOS.
    private func brightnessKey(up: Bool, fine: Bool) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard Preferences.brightnessKeys,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
              let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value,
              let display = Displays.external().first(where: { $0.id == id }),
              let level = Brightness.shared.step(display, up: up, fine: fine) else { return false }
        BrightnessHUD.shared.show(level, on: screen)
        return true
    }

    private func addBrightnessRow(for display: ExternalDisplay) {
        let level = Brightness.shared.level(display)
        let row = BrightnessSliderView(value: level ?? 0.5) { Brightness.shared.set(display, fraction: $0) }
        row.slider.isEnabled = level != nil
        let item = NSMenuItem()
        item.view = row
        menu.addItem(item)

        switch Brightness.shared.method(display) {
        case .hardware:
            row.toolTip = L("Monitor backlight (DDC/CI)")
        case .software:
            row.toolTip = L("Software dimming: the monitor does not accept brightness over DDC/CI")
            menu.addItem(disabled(L("The monitor ignores brightness commands, so dimming is done in software.")))
            menu.addItem(disabled(L("For backlight control, turn off brightness-locking modes in the monitor's menu")))
            menu.addItem(disabled(L("(e.g. MPRT, dynamic contrast, Eco, HDR).")))
            let retry = NSMenuItem(title: L("Check Monitor Again"), action: #selector(probeAgain(_:)), keyEquivalent: "")
            retry.target = self
            retry.representedObject = DisplayRef(display)
            menu.addItem(retry)
        case nil:
            row.toolTip = L("Checking whether the monitor accepts brightness commands…")
        }
    }

    @objc private func probeAgain(_ sender: NSMenuItem) {
        guard let display = (sender.representedObject as? DisplayRef)?.display else { return }
        Brightness.shared.probe(display) { [weak self] method in
            self?.alert(method == .hardware
                ? L("The monitor now accepts brightness commands: the keys and the slider control its backlight.")
                : L("The monitor still ignores brightness commands. In its menu, make sure modes such as MPRT, dynamic contrast, Eco and HDR are off and Brightness is not greyed out."))
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let displays = Displays.external()
        if displays.isEmpty {
            menu.addItem(disabled(L("No external monitor found")))
        }
        for display in displays {
            addSection(for: display)
            menu.addItem(.separator())
        }
        addGlobalItems()
    }

    private func addSection(for display: ExternalDisplay) {
        let current = display.currentMode
        menu.addItem(header(display.name))
        if let current {
            let kind = current.spec.isHiDPI ? L("Retina, smoothed") : L("not HiDPI, text is not smoothed")
            menu.addItem(disabled(L("Now: %@ · %@ · %ld Hz", current.spec.size, kind, Int(current.refreshRate.rounded()))))
        }
        addBrightnessRow(for: display)

        for preset in display.presets() {
            menu.addItem(modeItem("\(preset.title)  (\(preset.mode.spec.size))", preset.mode, display, current))
        }

        let others = NSMenu()
        let retina = display.retinaModes()
        for (index, mode) in retina.enumerated() where index % 4 == 0 || mode.spec == current?.spec {
            others.addItem(modeItem(mode.spec.size, mode, display, current))
        }
        if others.numberOfItems > 0 {
            let item = NSMenuItem(title: L("More Retina Sizes"), action: nil, keyEquivalent: "")
            item.submenu = others
            menu.addItem(item)
        }

        if let native = display.nativeMode() {
            menu.addItem(modeItem(L("Standard Mode, No HiDPI  (%@)", native.spec.size), native, display, current))
        }

        addColorMenu(for: display)

        if !display.hasNearNativeRetina {
            if unlocking.contains(display.key) {
                menu.addItem(disabled(L("Unlock Retina Modes…")))
            } else if RetinaUnlock.isInstalled(for: display) {
                menu.addItem(disabled(L("Retina unlocked — reconnect the monitor cable")))
            } else {
                let item = NSMenuItem(title: L("Unlock Retina Modes…"), action: #selector(unlockRetina(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = DisplayRef(display)
                menu.addItem(item)
            }
        }
    }

    private func addColorMenu(for display: ExternalDisplay) {
        let current = ColorProfiles.currentURL(display)
        let colors = NSMenu()
        colors.addItem(disabled(L("White point (profile built from the panel's real primaries)")))
        for target in WhiteTarget.allCases {
            let item = colorItem(target.title, ColorChoice(display, target: target))
            item.state = current?.standardizedFileURL == ColorProfiles.profileURL(display, target).standardizedFileURL ? .on : .off
            colors.addItem(item)
        }
        colors.addItem(.separator())
        let factory = colorItem(L("macOS Factory Profile (from monitor data)"), ColorChoice(display))
        factory.state = current != nil && current == ColorProfiles.factoryURL(display) ? .on : .off
        colors.addItem(factory)
        colors.addItem(.separator())
        colors.addItem(disabled(L("Turn off True Tone on the built-in display when comparing")))

        let item = NSMenuItem(title: L("Colors: %@", current.map(ColorProfiles.name) ?? L("unknown")), action: nil, keyEquivalent: "")
        item.submenu = colors
        menu.addItem(item)
    }

    private func colorItem(_ title: String, _ choice: ColorChoice) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseColor(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = choice
        return item
    }

    private func addGlobalItems() {
        if MediaKeys.isAllowed {
            addToggle(L("Brightness Keys Control the Monitor Under the Pointer"), Preferences.brightnessKeys, #selector(toggleBrightnessKeys))
        } else {
            let allow = NSMenuItem(title: L("Allow Brightness Keys…"), action: #selector(allowBrightnessKeys), keyEquivalent: "")
            allow.target = self
            menu.addItem(allow)
        }
        addToggle(L("Keep Mode After Reconnect and Sleep"), Preferences.keepModes, #selector(toggleKeep))
        addToggle(L("Launch at Login"), LoginItem.isEnabled, #selector(toggleLogin))
        addToggle(L("Thinner Text (applies after apps restart)"), FontSmoothing.isThin, #selector(toggleThinFont))

        addLanguageMenu()

        menu.addItem(.separator())
        addAction(L("Display Settings…"), #selector(openDisplaySettings))
        addAction(L("Check for Updates…"), #selector(checkForUpdates))
        addToggle(L("Check for Updates Automatically"), Updates.automatic, #selector(toggleAutomaticUpdates))
        addAction(L("About SmoothDisplay"), #selector(about))
        menu.addItem(NSMenuItem(title: L("Quit SmoothDisplay"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addLanguageMenu() {
        let languages = NSMenu()
        let system = NSMenuItem(title: L("Same as System"), action: #selector(chooseLanguage(_:)), keyEquivalent: "")
        system.target = self
        system.state = Localization.chosen == nil ? .on : .off
        languages.addItem(system)
        languages.addItem(.separator())
        for language in Localization.languages {
            let item = NSMenuItem(title: language.name, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.code
            item.state = Localization.chosen == language.code ? .on : .off
            languages.addItem(item)
        }
        let item = NSMenuItem(title: L("Language"), action: nil, keyEquivalent: "")
        item.submenu = languages
        menu.addItem(item)
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        Localization.chosen = sender.representedObject as? String
    }

    private func addToggle(_ title: String, _ on: Bool, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = on ? .on : .off
        item.target = self
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func modeItem(_ title: String, _ mode: CGDisplayMode, _ display: ExternalDisplay, _ current: CGDisplayMode?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseMode(_:)), keyEquivalent: "")
        item.target = self
        item.state = mode.spec == current?.spec ? .on : .off
        item.representedObject = ModeChoice(display, spec: mode.spec)
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        item.isEnabled = false
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ModeChoice,
              let display = choice.display,
              let mode = display.mode(matching: choice.spec) else { return }
        lastOwnModeChange = Date()
        if Displays.apply(mode, to: display.id) {
            Preferences.setDesiredMode(choice.spec, for: display)
        } else {
            alert(L("Couldn't switch to %@.", choice.spec.size))
        }
    }

    @objc private func chooseColor(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ColorChoice, let display = choice.display else { return }
        do {
            let profile = try choice.target.map { try ColorProfiles.generate(display, $0) } ?? choice.profile
            if ColorProfiles.assign(profile, to: display) {
                profilesChanged()
            } else {
                alert(L("macOS did not accept the color profile."))
            }
        } catch {
            alert(error.localizedDescription)
        }
    }

    @objc private func toggleKeep() { Preferences.keepModes.toggle() }

    @objc private func toggleBrightnessKeys() {
        Preferences.brightnessKeys.toggle()
        if Preferences.brightnessKeys {
            startBrightnessKeys()
        } else {
            keys.stop()
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    @objc private func toggleAutomaticUpdates() { Updates.automatic.toggle() }

    @objc private func checkForUpdates() { Updates.check(userInitiated: true) }

    @objc private func allowBrightnessKeys() {
        Preferences.brightnessKeys = true
        MediaKeys.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        startBrightnessKeys()
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            alert(L("Couldn't change Launch at Login: %@", error.localizedDescription))
        }
    }

    @objc private func toggleThinFont() { FontSmoothing.setThin(!FontSmoothing.isThin) }

    @objc private func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: L("Smooth text on non-Retina monitors, brightness keys and color profiles for external displays.") + "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: AppInfo.repositoryURL.absoluteString,
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .link: AppInfo.repositoryURL]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func unlockRetina(_ sender: NSMenuItem) {
        guard let display = (sender.representedObject as? DisplayRef)?.display,
              unlocking.insert(display.key).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RetinaUnlock.install(for: display) }
            DispatchQueue.main.async { [weak self] in
                self?.unlocking.remove(display.key)
                switch result {
                case .success:
                    self?.alert(L("Done. Unplug and reconnect the monitor cable (or restart the Mac); Retina modes will then appear in the menu."))
                case .failure(let error):
                    self?.alert(error.localizedDescription)
                }
            }
        }
    }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "SmoothDisplay"
        alert.informativeText = text
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}
