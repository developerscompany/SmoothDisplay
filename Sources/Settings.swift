import AppKit
import ServiceManagement

/// The mode the user picked for each monitor, restored after reconnect or wake.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var welcomed: Bool {
        get { defaults.bool(forKey: "welcomed") }
        set { defaults.set(newValue, forKey: "welcomed") }
    }

    /// Carries settings over from the prototype build, which used the bundle id "local.smoothdisplay".
    /// The Accessibility grant cannot be carried over: it belongs to the old signature.
    static func migrateFromPrototype() {
        guard !defaults.bool(forKey: "migratedPrototype") else { return }
        defaults.set(true, forKey: "migratedPrototype")
        guard let old = defaults.persistentDomain(forName: "local.smoothdisplay") else { return }
        for (key, value) in old where key != "accessibilityPrompted" && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        welcomed = true
    }

    static var keepModes: Bool {
        get { defaults.object(forKey: "keepModes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepModes") }
    }

    /// Brightness keys adjust the external monitor while the pointer is on it.
    static var brightnessKeys: Bool {
        get { defaults.object(forKey: "brightnessKeys") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "brightnessKeys") }
    }

    static func desiredMode(for display: ExternalDisplay) -> ModeSpec? {
        guard let data = defaults.data(forKey: "mode.\(display.key)") else { return nil }
        return try? JSONDecoder().decode(ModeSpec.self, from: data)
    }

    static func setDesiredMode(_ spec: ModeSpec, for display: ExternalDisplay) {
        defaults.set(try? JSONEncoder().encode(spec), forKey: "mode.\(display.key)")
    }
}

/// macOS "font smoothing" is stem darkening since Big Sur: off makes text thinner.
/// Same switch as `defaults -currentHost write -g AppleFontSmoothing -int 0`.
enum FontSmoothing {
    private static let key = "AppleFontSmoothing" as CFString

    static var isThin: Bool {
        let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (value as? NSNumber)?.intValue == 0
    }

    static func setThin(_ thin: Bool) {
        CFPreferencesSetValue(key, thin ? NSNumber(value: 0) : nil,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Display override plist that makes macOS offer Retina modes for a monitor that has none.
/// Lives in /Library/Displays (needs an admin password once) and takes effect after reconnecting the monitor.
enum RetinaUnlock {
    static func path(for display: ExternalDisplay) -> String {
        "/Library/Displays/Contents/Resources/Overrides"
            + "/DisplayVendorID-\(String(display.vendor, radix: 16))"
            + "/DisplayProductID-\(String(display.model, radix: 16))"
    }

    static func isInstalled(for display: ExternalDisplay) -> Bool {
        FileManager.default.fileExists(atPath: path(for: display))
    }

    /// Backing sizes from 2× the panel down to 1× in 32 px steps; each becomes a HiDPI mode at half that size.
    static func plist(for display: ExternalDisplay, nativeWidth: Int, nativeHeight: Int) throws -> Data {
        func bigEndian(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
        var resolutions: [Data] = []
        var width = nativeWidth * 2
        while width >= nativeWidth {
            let height = Int((Double(width) * Double(nativeHeight) / Double(nativeWidth)).rounded())
            resolutions.append(bigEndian(width) + bigEndian(height))
            width -= 32
        }
        let dict: [String: Any] = [
            "DisplayProductName": display.name,
            "DisplayVendorID": Int(display.vendor),
            "DisplayProductID": Int(display.model),
            "scale-resolutions": resolutions,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    static func install(for display: ExternalDisplay) throws {
        guard let native = display.nativeMode() else { throw message(L("Couldn't determine the monitor's resolution.")) }
        // The plist travels inside the command as base64 ([A-Za-z0-9+/=], safe in single quotes) rather than
        // through a temp file that another process could swap while the password dialog is open.
        let encoded = try plist(for: display, nativeWidth: native.width, nativeHeight: native.height).base64EncodedString()
        let dest = path(for: display) // hex ids only
        let dir = (dest as NSString).deletingLastPathComponent
        let shell = "mkdir -p '\(dir)' && echo '\(encoded)' | /usr/bin/base64 -D > '\(dest).tmp'"
            + " && chown root:wheel '\(dest).tmp' && chmod 644 '\(dest).tmp' && mv -f '\(dest).tmp' '\(dest)'"
        let prompt = L("SmoothDisplay wants to unlock Retina modes for your monitor.")
            .replacingOccurrences(of: "\"", with: "'")

        // osascript rather than NSAppleScript, so the hardened runtime needs no Apple Events entitlement.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(shell)\" with prompt \"\(prompt)\" with administrator privileges"]
        let errors = Pipe()
        task.standardError = errors
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw message(detail.contains("-128") ? L("Cancelled.") : L("Couldn't write the override file: %@", detail))
        }
    }

    private static func message(_ text: String) -> NSError {
        NSError(domain: "SmoothDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
