import AppKit
import ServiceManagement

/// Command line mode, for scripts and quick checks (English only):
///   SmoothDisplay --list
///   SmoothDisplay --apply 3424x1433     (Retina mode of that size, remembered like a menu choice)
///   SmoothDisplay --native              (plain 1× mode)
///   SmoothDisplay --brightness [0-100]  (probe DDC, optionally set the backlight)
///   SmoothDisplay --color [d65|6000k|5500k|native|factory]
///   SmoothDisplay --login on|off        (start at login)
func runCommandLine(_ args: [String]) -> Int32 {
    Localization.englishOnly = true
    Brightness.shared.appliesDimming = false
    if args.first == "--login" {
        do {
            if let value = args.dropFirst().first {
                try LoginItem.setEnabled(value == "on")
            }
            print("Launch at login: \(LoginItem.isEnabled ? "on" : "off") (status \(SMAppService.mainApp.status.rawValue))")
            return 0
        } catch {
            print("Couldn't change launch at login: \(error.localizedDescription)")
            return 1
        }
    }

    let displays = Displays.external()
    guard let display = displays.first else {
        print("No external monitor found")
        return 1
    }

    func apply(_ mode: CGDisplayMode) -> Int32 {
        guard Displays.apply(mode, to: display.id) else {
            print("Couldn't switch to \(mode.spec.size)")
            return 1
        }
        Preferences.setDesiredMode(mode.spec, for: display)
        print("\(display.name): \(mode.spec.size) (\(mode.spec.pixelWidth)×\(mode.spec.pixelHeight) px) @\(Int(mode.refreshRate)) Hz")
        return 0
    }

    switch args.first {
    case "--list":
        for d in displays {
            print("\(d.name) [\(d.key)]")
            if let cur = d.currentMode {
                print("  now: \(cur.spec.size) px \(cur.pixelWidth)×\(cur.pixelHeight) @\(Int(cur.refreshRate)) \(cur.spec.isHiDPI ? "HiDPI" : "1×")")
            }
            if let native = d.nativeMode() { print("  panel: \(native.spec.size)") }
            for p in d.presets() {
                print("  \(p.title): \(p.mode.spec.size) px \(p.mode.pixelWidth)×\(p.mode.pixelHeight) @\(Int(p.mode.refreshRate))")
            }
            print("  Retina sizes: \(d.retinaModes().count), remembered mode: \(Preferences.desiredMode(for: d)?.size ?? "none")")
        }
        return 0
    case "--apply":
        // Accept both "3424x1433" and the "3424×1433" that --list prints.
        let parts = args.dropFirst().first?.lowercased()
            .split(whereSeparator: { $0 == "x" || $0 == "×" }).compactMap { Int($0) } ?? []
        guard parts.count == 2,
              let mode = display.retinaModes().first(where: { $0.width == parts[0] && $0.height == parts[1] })
        else {
            print("No such Retina mode. See --list")
            return 1
        }
        return apply(mode)
    case "--native":
        guard let mode = display.nativeMode() else { return 1 }
        return apply(mode)
    case "--brightness":
        var method: Brightness.Method?
        Brightness.shared.probe(display) { method = $0 }
        while method == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if method == .hardware, let value = args.dropFirst().first.flatMap(Double.init) {
            Brightness.shared.set(display, fraction: value / 100)
            Brightness.shared.flush()
            usleep(300_000)
        }
        let reported = Brightness.shared.readFromMonitor(display)
        print("\(display.name): method \(method == .hardware ? "hardware (DDC)" : "software"), "
              + "monitor reports \(reported.map { "\($0.current) of \($0.maximum)" } ?? "nothing")")
        return 0
    case "--color":
        if let choice = args.dropFirst().first?.lowercased() {
            let target = WhiteTarget.allCases.first { $0.fileTag.lowercased() == choice }
            guard target != nil || choice == "factory" else {
                print("Options: \(WhiteTarget.allCases.map { $0.fileTag.lowercased() }.joined(separator: ", ")), factory")
                return 1
            }
            do {
                let profile = try target.map { try ColorProfiles.generate(display, $0) }
                guard ColorProfiles.assign(profile, to: display) else {
                    print("macOS did not accept the color profile")
                    return 1
                }
                Thread.sleep(forTimeInterval: 1)
            } catch {
                print(error.localizedDescription)
                return 1
            }
        }
        printColorState(display)
        return 0
    default:
        print("Usage: SmoothDisplay [--list | --apply WxH | --native | --brightness [0-100] | --color [d65|6000k|5500k|native|factory] | --login on|off]")
        return 1
    }
}

func printColorState(_ display: ExternalDisplay) {
    if let url = ColorProfiles.currentURL(display) {
        print("Profile: \(ColorProfiles.name(of: url))  [\(url.path)]")
    }
    if let g = ColorProfiles.panelGamut(display) {
        print(String(format: "Panel (EDID): R %.4f,%.4f  G %.4f,%.4f  B %.4f,%.4f  white %.4f,%.4f  gamma %.2f",
                     g.red.x, g.red.y, g.green.x, g.green.y, g.blue.x, g.blue.y, g.white.x, g.white.y, g.gamma))
    }
    // What the display pipeline actually outputs for full-scale R, G, B: shows whether a vcgt took effect.
    var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
    var count: UInt32 = 0
    if CGGetDisplayTransferByTable(display.id, 256, &r, &g, &b, &count) == .success, count > 0 {
        let last = Int(count) - 1
        print(String(format: "Output table, channel maximum: R %.3f  G %.3f  B %.3f", r[last], g[last], b[last]))
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, first.hasPrefix("--") {
    exit(runCommandLine(arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
