import AppKit
import IOKit

/// Short troubleshooting log in ~/Library/Logs/SmoothDisplay.log (unified-log info messages are not kept on disk).
enum DebugLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SmoothDisplay.log")
    private static let queue = DispatchQueue(label: "local.smoothdisplay.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 512_000 {
                try? FileManager.default.removeItem(at: url)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? line.data(using: .utf8)?.write(to: url)
                return
            }
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        }
    }
}

/// DDC/CI channel of an external monitor on Apple Silicon (IOAVService, private API used by every DDC tool on M-series Macs).
final class DDC {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias CopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn

    private struct API {
        let create: Create
        let read: I2C
        let write: I2C
        let edid: CopyEDID
    }

    private static let api: API? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C"),
              let edid = dlsym(handle, "IOAVServiceCopyEDID") else { return nil }
        return API(create: unsafeBitCast(create, to: Create.self),
                   read: unsafeBitCast(read, to: I2C.self),
                   write: unsafeBitCast(write, to: I2C.self),
                   edid: unsafeBitCast(edid, to: CopyEDID.self))
    }()

    private let service: CFTypeRef

    private init(_ service: CFTypeRef) { self.service = service }

    /// Finds the channel whose EDID belongs to `display`. Identical monitors are matched in registry order,
    /// which is a best effort: the registry does not say which port a proxy belongs to.
    static func channel(for display: ExternalDisplay) -> DDC? {
        guard let api else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var unidentified: [DDC] = []
        var matches: [DDC] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let service = api.create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            let channel = DDC(service)
            var edid: Unmanaged<CFData>?
            guard api.edid(service, &edid) == kIOReturnSuccess, let bytes = edid?.takeRetainedValue() as Data?, bytes.count > 15 else {
                unidentified.append(channel)
                continue
            }
            let vendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
            let product = UInt32(bytes[11]) << 8 | UInt32(bytes[10])
            let serial = (12..<16).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[$1]) }
            if vendor == display.vendor, product == display.model, serial == display.serial || display.serial == 0 {
                matches.append(channel)
            }
        }
        if display.twinIndex < matches.count { return matches[display.twinIndex] }
        if matches.isEmpty, unidentified.count == 1, Displays.external().count == 1 { return unidentified[0] }
        return matches.first
    }

    @discardableResult
    func write(_ code: UInt8, _ value: UInt16) -> Bool {
        guard let api = Self.api else { return false }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ 0x51, ^)
        var sent = false
        for _ in 0..<2 { // some monitors drop the first packet
            usleep(10_000)
            sent = api.write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess || sent
        }
        return sent
    }

    func read(_ code: UInt8) -> (current: Int, maximum: Int)? {
        guard let api = Self.api else { return nil }
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = request[0..<3].reduce(0x6E, ^)
        for attempt in 0..<3 {
            for _ in 0..<2 {
                usleep(10_000)
                _ = api.write(service, 0x37, 0x51, &request, UInt32(request.count))
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            // 6E 88 02 result code type maxH maxL curH curL checksum
            if api.read(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               reply[2] == 0x02, reply[3] == 0x00, reply[4] == code {
                let maximum = Int(reply[6]) << 8 | Int(reply[7])
                if maximum > 0 { return (Int(reply[8]) << 8 | Int(reply[9]), maximum) }
            }
            usleep(20_000 * UInt32(attempt + 1))
        }
        return nil
    }
}

/// Monitor brightness. Prefers the backlight over DDC (VCP 0x10); when the monitor ignores DDC writes
/// (on this MSI that happens while MPRT or HDCR is on), falls back to dimming the picture in software.
/// DDC writes go to a background queue and are coalesced, so holding a key or dragging the slider
/// never queues up stale values.
final class Brightness {
    static let shared = Brightness()

    enum Method: String {
        case hardware, software
    }

    private let queue = DispatchQueue(label: "local.smoothdisplay.ddc")
    private var channels: [String: DDC] = [:]  // queue only
    private var methods: [String: Method] = [:]  // main thread only
    private var maximums: [String: Int] = [:]  // main thread only
    private var fractions: [String: Double] = [:]  // main thread only
    private let lock = NSLock()
    private var pending: [String: (display: ExternalDisplay, value: Int)] = [:]

    /// Command line runs must not touch gamma tables: that would undo the menu bar app's dimming.
    var appliesDimming = true

    /// Forget DDC channels after a monitor was reconnected. The last known method and level stay, so the keys
    /// keep working until the next probe confirms them.
    func reset() {
        queue.async { self.channels.removeAll() }
    }

    private func channel(_ display: ExternalDisplay) -> DDC? {
        if let cached = channels[display.key] { return cached }
        let found = DDC.channel(for: display)
        channels[display.key] = found
        return found
    }

    func method(_ display: ExternalDisplay) -> Method? { methods[display.key] }

    private func softwareKey(_ display: ExternalDisplay) -> String { "softwareBrightness.\(display.key)" }

    /// Finds out whether the monitor obeys DDC brightness: nudges it by one step, reads back, puts it back.
    /// A monitor that is still waking up (no answer, or a stale one) gets a few more tries before it is
    /// declared software-only.
    func probe(_ display: ExternalDisplay, then done: @escaping (Method) -> Void = { _ in }) {
        queue.async {
            var outcome: (method: Method, current: Int, maximum: Int) = (.software, 0, 100)
            for (attempt, pause) in [0, 500_000, 1_000_000, 2_000_000].enumerated() {
                usleep(UInt32(pause))
                if attempt > 0 { self.channels[display.key] = nil } // the proxy may have been recreated
                guard let channel = self.channel(display), let before = channel.read(0x10) else {
                    DebugLog.write("probe \(display.name) #\(attempt + 1): no DDC answer")
                    continue
                }
                let test = before.current < before.maximum ? before.current + 1 : before.current - 1
                channel.write(0x10, UInt16(test))
                usleep(300_000)
                let after = channel.read(0x10)
                channel.write(0x10, UInt16(before.current)) // harmless when the test write was ignored
                let accepted = after?.current == test
                DebugLog.write("probe \(display.name) #\(attempt + 1): DDC \(before.current)/\(before.maximum), wrote \(test), read \(after.map { "\($0.current)" } ?? "nothing")")
                outcome = (accepted ? .hardware : .software, before.current, before.maximum)
                // An answer that ignored the write is worth one retry; a clear yes is final.
                if accepted || (after != nil && attempt >= 1) { break }
            }
            DebugLog.write("probe \(display.name) -> \(outcome.method)")
            DispatchQueue.main.async {
                self.methods[display.key] = outcome.method
                self.maximums[display.key] = outcome.maximum
                switch outcome.method {
                case .hardware:
                    self.fractions[display.key] = Double(outcome.current) / Double(outcome.maximum)
                    if self.appliesDimming { SoftwareDimming.apply(1, to: display.id) }
                case .software:
                    let level = UserDefaults.standard.object(forKey: self.softwareKey(display)) as? Double ?? 1
                    self.fractions[display.key] = level
                    if self.appliesDimming { SoftwareDimming.apply(level, to: display.id) }
                }
                done(outcome.method)
            }
        }
    }

    /// Current level 0…1, `nil` until the monitor has been probed.
    func level(_ display: ExternalDisplay) -> Double? { fractions[display.key] }

    func set(_ display: ExternalDisplay, fraction: Double) {
        guard let method = methods[display.key] else { return }
        let fraction = min(1, max(0, fraction))
        fractions[display.key] = fraction
        switch method {
        case .software:
            UserDefaults.standard.set(fraction, forKey: softwareKey(display))
            SoftwareDimming.apply(fraction, to: display.id)
        case .hardware:
            let value = Int((fraction * Double(maximums[display.key] ?? 100)).rounded())
            lock.lock()
            let idle = pending.isEmpty
            pending[display.key] = (display, value)
            lock.unlock()
            if idle { queue.async { self.drain() } }
        }
    }

    /// One brightness key press: 16 steps like the built-in screen, 64 with Option+Shift.
    func step(_ display: ExternalDisplay, up: Bool, fine: Bool) -> Double? {
        guard let level = level(display) else { return nil }
        let size = fine ? 1.0 / 64 : 1.0 / 16
        let next = min(1, max(0, ((level / size).rounded() + (up ? 1 : -1)) * size))
        set(display, fraction: next)
        return next
    }

    /// What the monitor itself reports right now.
    func readFromMonitor(_ display: ExternalDisplay) -> (current: Int, maximum: Int)? {
        queue.sync { channel(display)?.read(0x10) }
    }

    /// Waits until queued DDC writes have gone out.
    func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (key, item) = pending.first else {
                lock.unlock()
                return
            }
            pending[key] = nil
            lock.unlock()
            let sent = channel(item.display)?.write(0x10, UInt16(item.value)) == true
            DebugLog.write("DDC write \(item.display.name) brightness=\(item.value) \(sent ? "ok" : "FAILED")")
        }
    }
}

/// Dims a display by scaling its gamma table, on top of whatever ColorSync loaded from the profile (vcgt included).
/// macOS drops these tables when the app quits, so nothing stays dimmed by accident.
enum SoftwareDimming {
    private static var levels: [CGDirectDisplayID: Double] = [:]
    private static var baselines: [CGDirectDisplayID: [[CGGammaValue]]] = [:]

    static func apply(_ level: Double, to id: CGDirectDisplayID) {
        let previous = levels[id]
        levels[id] = level
        if level >= 0.999 && (previous == nil || previous! >= 0.999) { return }
        if baselines[id] == nil { captureBaselines() }
        write(id)
    }

    /// ColorSync replaced the tables (profile change, reconnect, wake): take fresh baselines and dim again.
    static func reapply() {
        baselines.removeAll()
        guard levels.values.contains(where: { $0 < 0.999 }) else { return }
        captureBaselines()
        levels.keys.forEach(write)
    }

    static func restoreAll() {
        levels.removeAll()
        baselines.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    private static func captureBaselines() {
        CGDisplayRestoreColorSyncSettings()
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        for id in ids.prefix(Int(count)) {
            let capacity = Int(CGDisplayGammaTableCapacity(id))
            var r = [CGGammaValue](repeating: 0, count: capacity), g = r, b = r
            var sampled: UInt32 = 0
            if CGGetDisplayTransferByTable(id, UInt32(capacity), &r, &g, &b, &sampled) == .success, sampled > 1 {
                let n = Int(sampled)
                baselines[id] = [Array(r.prefix(n)), Array(g.prefix(n)), Array(b.prefix(n))]
            }
        }
        // The restore above undid every display's dimming, not only this one.
        for id in levels.keys where baselines[id] != nil { write(id) }
    }

    private static func write(_ id: CGDirectDisplayID) {
        guard let base = baselines[id], let level = levels[id] else { return }
        // Perceptual: the level is a luminance fraction, the table scales the gamma-encoded signal.
        let scale = CGGammaValue(pow(max(0.03, min(1, level)), 1 / 2.2))
        var r = base[0].map { $0 * scale }, g = base[1].map { $0 * scale }, b = base[2].map { $0 * scale }
        let result = CGSetDisplayTransferByTable(id, UInt32(r.count), &r, &g, &b)
        if result != .success { DebugLog.write("software dimming failed on display \(id): \(result.rawValue)") }
    }
}

/// Brightness keys of the built-in keyboard (and Apple keyboards). Needs Accessibility permission to swallow the key.
/// The tap only receives system-defined (media key) events, never ordinary keystrokes.
final class MediaKeys {
    /// Return true when the key was handled and must not reach macOS.
    var onBrightness: ((_ up: Bool, _ fine: Bool) -> Bool)?
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastDownHandled = false

    static var isAllowed: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let keys = Unmanaged<MediaKeys>.fromOpaque(refcon!).takeUnretainedValue()
                return keys.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        DebugLog.write("brightness key tap started")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        isRunning = false
        DebugLog.write("brightness key tap stopped")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        guard key == 2 || key == 3 else { return false } // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        if (ns.data1 & 0xFF00) >> 8 == 0x0A { // key down, including auto-repeat
            let flags = NSEvent.modifierFlags
            lastDownHandled = onBrightness?(key == 2, flags.contains(.option) && flags.contains(.shift)) ?? false
            DebugLog.write("brightness key \(key == 2 ? "up" : "down") -> \(lastDownHandled ? "external monitor" : "macOS")")
        }
        // The key-up goes wherever its key-down went.
        return lastDownHandled
    }
}

/// Small on-screen indicator, the external-monitor counterpart of the system brightness HUD.
final class BrightnessHUD {
    static let shared = BrightnessHUD()

    private var panel: NSPanel?
    private let bar = LevelBar()
    private let percent = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?

    func show(_ level: Double, on screen: NSScreen) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        bar.level = level
        bar.needsDisplay = true
        percent.stringValue = "\(Int((level * 100).rounded()))%"

        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 90))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hide?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { panel?.orderOut(nil) })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: 330, height: 54)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // A neutral material, so the wallpaper colour does not leak into the indicator.
        let background = NSVisualEffectView(frame: frame)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 16, y: 15, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: L("Brightness"))
        icon.contentTintColor = .labelColor
        bar.frame = NSRect(x: 52, y: 21, width: 210, height: 12)
        percent.frame = NSRect(x: 270, y: 17, width: 48, height: 20)
        percent.alignment = .right
        percent.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        percent.textColor = .labelColor

        [icon, bar, percent].forEach(background.addSubview)
        panel.contentView = background
        return panel
    }
}

final class LevelBar: NSView {
    var level = 0.0

    override func draw(_ dirtyRect: NSRect) {
        let segments = 16
        let gap: CGFloat = 3
        let width = (bounds.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let filled = level * Double(segments)
        for i in 0..<segments {
            let rect = NSRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: bounds.height)
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            let part = min(1, max(0, filled - Double(i)))
            if part > 0 {
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: 0, width: rect.width * part, height: rect.height),
                             xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}

/// Slider row for the status menu.
final class BrightnessSliderView: NSView {
    let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let onChange: (Double) -> Void

    init(value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let low = NSImageView(frame: NSRect(x: 20, y: 7, width: 16, height: 16))
        low.image = NSImage(systemSymbolName: "sun.min", accessibilityDescription: nil)
        let high = NSImageView(frame: NSRect(x: 266, y: 6, width: 18, height: 18))
        high.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
        slider.frame = NSRect(x: 42, y: 5, width: 218, height: 20)
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        [low, slider, high].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func changed() { onChange(slider.doubleValue) }
}
