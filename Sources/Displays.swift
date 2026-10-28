import AppKit
import CoreGraphics

/// Resolution of a display mode: logical size ("looks like") and the backing pixel size.
/// A mode is HiDPI (Retina) when the backing store is larger than the logical size.
struct ModeSpec: Codable, Hashable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int

    var isHiDPI: Bool { pixelWidth > width }
    var size: String { "\(width)×\(height)" }
}

extension CGDisplayMode {
    var spec: ModeSpec {
        ModeSpec(width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}

struct Preset {
    let title: String
    let mode: CGDisplayMode
}

struct ExternalDisplay {
    let id: CGDirectDisplayID
    let name: String
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    /// Position among online monitors with the same vendor, model and serial (identical monitors often
    /// report serial 0), ordered by unit number; 0 when the monitor is unique.
    var twinIndex = 0
    var hasTwins = false

    /// Stable across reconnects, unlike CGDirectDisplayID. Identical monitors are told apart by unit number.
    var key: String {
        let base = String(format: "%x-%x-%x", vendor, model, serial)
        return hasTwins ? "\(base)-u\(CGDisplayUnitNumber(id))" : base
    }

    var currentMode: CGDisplayMode? { CGDisplayCopyDisplayMode(id) }

    /// Every resolution the display offers, HiDPI duplicates included,
    /// keeping only the fastest refresh rate for each resolution.
    func modes() -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }
        var best: [ModeSpec: CGDisplayMode] = [:]
        for mode in all where mode.isUsableForDesktopGUI() {
            if let kept = best[mode.spec], kept.refreshRate >= mode.refreshRate { continue }
            best[mode.spec] = mode
        }
        return best.values.sorted { ($0.width, $0.pixelWidth) > ($1.width, $1.pixelWidth) }
    }

    func mode(matching spec: ModeSpec) -> CGDisplayMode? {
        modes().first { $0.spec == spec }
    }

    /// The panel's physical resolution, 1:1 pixels.
    func nativeMode() -> CGDisplayMode? {
        let plain = modes().filter { !$0.spec.isHiDPI }
        let kDisplayModeNativeFlag: UInt32 = 0x0200_0000
        return plain.first { $0.ioFlags & kDisplayModeNativeFlag != 0 }
            ?? plain.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// HiDPI modes with the panel's aspect ratio, between half the panel size and the panel itself.
    func retinaModes() -> [CGDisplayMode] {
        guard let native = nativeMode() else { return [] }
        let aspect = Double(native.width) / Double(native.height)
        return modes().filter {
            $0.spec.isHiDPI
                && $0.width <= native.width
                && $0.width * 2 >= native.width
                && abs(Double($0.width) / Double($0.height) - aspect) < 0.02
        }
    }

    /// True when macOS offers a Retina mode close to the panel's own size.
    var hasNearNativeRetina: Bool {
        guard let native = nativeMode() else { return false }
        return retinaModes().contains { Double($0.width) >= Double(native.width) * 0.9 }
    }

    /// A short list of sensible Retina sizes: native-sized UI first, then progressively larger UI.
    func presets() -> [Preset] {
        guard let native = nativeMode() else { return [] }
        let retina = retinaModes()
        let steps: [(Double, String)] = [
            (1.00, L("Retina — native size")),
            (1.15, L("Retina — 15% larger")),
            (1.25, L("Retina — 25% larger")),
            (1.33, L("Retina — one third larger")),
            (1.50, L("Retina — 1.5× larger")),
        ]
        var used = Set<ModeSpec>()
        var result: [Preset] = []
        for (factor, title) in steps {
            let target = Double(native.width) / factor
            guard let mode = retina.min(by: { abs(Double($0.width) - target) < abs(Double($1.width) - target) }),
                  abs(Double(mode.width) - target) / target < 0.06,
                  used.insert(mode.spec).inserted
            else { continue }
            result.append(Preset(title: title, mode: mode))
        }
        return result
    }
}

enum Displays {
    static func external() -> [ExternalDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        var displays = ids.prefix(Int(count))
            .filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { id in
                ExternalDisplay(
                    id: id,
                    name: screenName(for: id) ?? L("Monitor %u", id),
                    vendor: CGDisplayVendorNumber(id),
                    model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id)
                )
            }
        for i in displays.indices {
            let twins = displays.filter {
                $0.vendor == displays[i].vendor && $0.model == displays[i].model && $0.serial == displays[i].serial
            }.sorted { CGDisplayUnitNumber($0.id) < CGDisplayUnitNumber($1.id) }
            displays[i].hasTwins = twins.count > 1
            displays[i].twinIndex = twins.firstIndex { $0.id == displays[i].id } ?? 0
        }
        return displays
    }

    /// Finds a monitor again for a menu action: by display id first, by key if it was reconnected meanwhile.
    static func find(id: CGDirectDisplayID, key: String) -> ExternalDisplay? {
        let all = external()
        return all.first { $0.id == id && $0.key == key } ?? all.first { $0.key == key }
    }

    @discardableResult
    static func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    private static func screenName(for id: CGDirectDisplayID) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }?.localizedName
    }
}
