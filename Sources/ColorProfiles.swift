import ColorSync
import CoreGraphics
import Foundation

/// CIE 1931 chromaticity.
struct XY: Equatable {
    var x: Double
    var y: Double

    /// XYZ with Y = 1.
    var xyz: [Double] { [x / y, 1, (1 - x - y) / y] }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(xyz v: [Double]) {
        let sum = v[0] + v[1] + v[2]
        self.init(x: v[0] / sum, y: v[1] / sum)
    }

    static let d65 = XY(x: 0.3127, y: 0.3290)

    /// A point on the CIE daylight locus, valid for 4000–25000 K.
    static func daylight(kelvin t: Double) -> XY {
        let x = t <= 7000
            ? -4.6070e9 / pow(t, 3) + 2.9678e6 / pow(t, 2) + 0.09911e3 / t + 0.244063
            : -2.0064e9 / pow(t, 3) + 1.9018e6 / pow(t, 2) + 0.24748e3 / t + 0.237040
        return XY(x: x, y: -3.000 * x * x + 2.870 * x - 0.275)
    }
}

/// What a panel physically does: primaries, white with all channels at full drive, and its tone response.
struct Gamut {
    var red: XY
    var green: XY
    var blue: XY
    var white: XY
    /// Effective gamma at mid-grey; only used to turn linear white-balance gains into signal scales.
    var gamma: Double
    /// The source profile's rTRC, gTRC, bTRC tags, copied verbatim so generated profiles keep its exact tone curve.
    var curves: [Data]? = nil

    /// Rejects degenerate data (bogus EDIDs, dummy plugs) that would turn the profile maths into NaN or infinity.
    var isUsable: Bool {
        let points = [red, green, blue, white]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.y > 0.001 && $0.x > 0 }),
              gamma.isFinite, gamma > 0.5, gamma < 5 else { return false }
        let p = Matrix.columns(red.xyz, green.xyz, blue.xyz)
        return abs(Matrix.determinant(p)) > 1e-4 && rgbToXYZ.allSatisfy(\.isFinite)
    }

    /// Linear RGB to XYZ, white at Y = 1.
    var rgbToXYZ: [Double] {
        let p = Matrix.columns(red.xyz, green.xyz, blue.xyz)
        return Matrix.mul(p, Matrix.diag(Matrix.apply(Matrix.inverse(p), white.xyz)))
    }
}

/// Row-major 3×3 matrices.
enum Matrix {
    static let d50 = [0.9642, 1.0, 0.8249]
    static let bradford = [0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296]

    static func columns(_ a: [Double], _ b: [Double], _ c: [Double]) -> [Double] {
        [a[0], b[0], c[0], a[1], b[1], c[1], a[2], b[2], c[2]]
    }

    static func column(_ m: [Double], _ i: Int) -> [Double] { [m[i], m[3 + i], m[6 + i]] }

    static func diag(_ v: [Double]) -> [Double] { [v[0], 0, 0, 0, v[1], 0, 0, 0, v[2]] }

    static func apply(_ m: [Double], _ v: [Double]) -> [Double] {
        (0..<3).map { r in m[r * 3] * v[0] + m[r * 3 + 1] * v[1] + m[r * 3 + 2] * v[2] }
    }

    static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        (0..<9).map { i in
            let r = i / 3, c = i % 3
            return a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
        }
    }

    static func determinant(_ m: [Double]) -> Double {
        m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
    }

    static func inverse(_ m: [Double]) -> [Double] {
        let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let det = determinant(m)
        return [e * i - f * h, c * h - b * i, b * f - c * e,
                f * g - d * i, a * i - c * g, c * d - a * f,
                d * h - e * g, b * g - a * h, a * e - b * d].map { $0 / det }
    }

    /// Bradford chromatic adaptation between two whites (XYZ).
    static func adaptation(from source: [Double], to destination: [Double]) -> [Double] {
        let s = apply(bradford, source), d = apply(bradford, destination)
        return mul(inverse(bradford), mul(diag([d[0] / s[0], d[1] / s[1], d[2] / s[2]]), bradford))
    }
}

// MARK: - ICC

enum ICC {
    /// Reads the panel description back out of a matrix/TRC display profile, e.g. the one macOS builds from EDID.
    static func gamut(from data: Data) -> Gamut? {
        guard data.count > 132 else { return nil }
        func u32(_ o: Int) -> UInt32 { data[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func s15(_ o: Int) -> Double { Double(Int32(bitPattern: u32(o))) / 65536 }
        var tags: [String: (offset: Int, size: Int)] = [:]
        for k in 0..<Int(u32(128)) {
            let o = 132 + k * 12
            guard o + 12 <= data.count, let sig = String(data: data[o..<o + 4], encoding: .ascii) else { return nil }
            let offset = Int(u32(o + 4)), size = Int(u32(o + 8))
            guard offset >= 0, size >= 8, offset + size <= data.count else { continue }
            tags[sig] = (offset, size)
        }
        func xyz(_ sig: String) -> [Double]? {
            tags[sig].flatMap { $0.size >= 20 ? [s15($0.offset + 8), s15($0.offset + 12), s15($0.offset + 16)] : nil }
        }
        guard let w = xyz("wtpt"), let r = xyz("rXYZ"), let g = xyz("gXYZ"), let b = xyz("bXYZ") else { return nil }

        // Colorants are stored adapted to D50; undo that to get the real primaries.
        let toPanel: [Double]
        if let chad = tags["chad"], chad.size >= 44 {
            toPanel = Matrix.inverse((0..<9).map { s15(chad.offset + 8 + $0 * 4) })
        } else {
            toPanel = Matrix.adaptation(from: Matrix.d50, to: w)
        }
        let white = r.indices.map { r[$0] + g[$0] + b[$0] }
        let curves = ["rTRC", "gTRC", "bTRC"].compactMap { sig in tags[sig].map { Data(data[$0.offset..<$0.offset + $0.size]) } }
        let gamut = Gamut(red: XY(xyz: Matrix.apply(toPanel, r)),
                          green: XY(xyz: Matrix.apply(toPanel, g)),
                          blue: XY(xyz: Matrix.apply(toPanel, b)),
                          white: XY(xyz: Matrix.apply(toPanel, white)),
                          gamma: curves.first.flatMap(effectiveGamma) ?? 2.2,
                          curves: curves.count == 3 ? curves : nil)
        return gamut.isUsable ? gamut : nil
    }

    /// Gamma that matches the tone curve at mid-grey, for `curv` tables and every `para` function type.
    private static func effectiveGamma(_ tag: Data) -> Double? {
        guard tag.count >= 12 else { return nil }
        let bytes = [UInt8](tag)
        func u32(_ o: Int) -> UInt32 { bytes[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func u16(_ o: Int) -> Double { Double(UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1])) }
        func s15(_ o: Int) -> Double { Double(Int32(bitPattern: u32(o))) / 65536 }
        let y: Double
        switch u32(0) {
        case 0x6375_7276: // 'curv'
            let count = Int(u32(8))
            guard count > 0, tag.count >= 12 + count * 2 else { return nil }
            if count == 1 { return u16(12) / 256 }
            let position = 0.5 * Double(count - 1)
            let i = Int(position), t = position - Double(i)
            y = (u16(12 + i * 2) * (1 - t) + u16(12 + min(i + 1, count - 1) * 2) * t) / 65535
        case 0x7061_7261: // 'para'
            let type = Int(u32(8) >> 16)
            let counts = [1, 3, 4, 5, 7]
            guard type < counts.count, tag.count >= 12 + counts[type] * 4 else { return nil }
            let p = (0..<counts[type]).map { s15(12 + $0 * 4) }
            let x = 0.5
            switch type {
            case 0: y = pow(x, p[0])
            case 1: y = x >= -p[2] / p[1] ? pow(p[1] * x + p[2], p[0]) : 0
            case 2: y = x >= -p[2] / p[1] ? pow(p[1] * x + p[2], p[0]) + p[3] : p[3]
            case 3: y = x >= p[4] ? pow(p[1] * x + p[2], p[0]) : p[3] * x
            default: y = x >= p[4] ? pow(p[1] * x + p[2], p[0]) + p[5] : p[3] * x + p[6]
            }
        default:
            return nil
        }
        guard y > 0, y < 1 else { return nil }
        return log(y) / log(0.5)
    }

    /// An ICC v2 matrix/TRC display profile for `panel`.
    /// With `white`, the profile also carries a `vcgt` that scales the channels so full white lands on that point,
    /// i.e. a software white balance done by the display pipeline.
    static func profile(name: String, panel: Gamut, white target: XY?) -> Data {
        let native = panel.rgbToXYZ
        var gains = [1.0, 1.0, 1.0]
        if let target {
            let raw = Matrix.apply(Matrix.inverse(native), target.xyz)
            let peak = raw.max() ?? 1
            gains = raw.map { max(0.05, $0 / peak) }
        }
        var colorants = Matrix.mul(native, Matrix.diag(gains))
        let whiteXYZ = Matrix.apply(colorants, [1, 1, 1])
        colorants = colorants.map { $0 / whiteXYZ[1] }
        let white = whiteXYZ.map { $0 / whiteXYZ[1] }
        let chad = Matrix.adaptation(from: white, to: Matrix.d50)
        let adapted = Matrix.mul(chad, colorants)

        var tags: [(String, Data)] = [
            ("desc", textDescription(name)),
            ("cprt", text("Generated by SmoothDisplay")),
            ("wtpt", xyzType(white)),
            ("rXYZ", xyzType(Matrix.column(adapted, 0))),
            ("gXYZ", xyzType(Matrix.column(adapted, 1))),
            ("bXYZ", xyzType(Matrix.column(adapted, 2))),
            ("rTRC", panel.curves?[0] ?? curve(panel.gamma)),
            ("gTRC", panel.curves?[1] ?? curve(panel.gamma)),
            ("bTRC", panel.curves?[2] ?? curve(panel.gamma)),
            ("chad", sf32(chad)),
        ]
        if target != nil {
            // Signal scale that gives the wanted linear gain on a panel with this gamma.
            tags.append(("vcgt", vcgtFormula(gains.map { pow($0, 1 / panel.gamma) })))
        }
        return assemble(tags)
    }

    private static func assemble(_ tags: [(String, Data)]) -> Data {
        var body = Data()
        var table = Data()
        let tableSize = 4 + tags.count * 12
        for (sig, data) in tags {
            let offset = 128 + tableSize + body.count
            table += ascii(sig) + u32(UInt32(offset)) + u32(UInt32(data.count))
            body += data
            while body.count % 4 != 0 { body.append(0) }
        }
        let size = 128 + tableSize + body.count

        let now = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date())
        var header = Data()
        header += u32(UInt32(size)) + ascii("appl") + u32(0x0210_0000)
        header += ascii("mntr") + ascii("RGB ") + ascii("XYZ ")
        for part in [now.year, now.month, now.day, now.hour, now.minute, now.second] {
            header += u16(UInt16(part ?? 0))
        }
        header += ascii("acsp") + ascii("APPL") + u32(0) + u32(0) + u32(0)
        header += Data(count: 8) + u32(0)
        header += s15(Matrix.d50[0]) + s15(Matrix.d50[1]) + s15(Matrix.d50[2])
        header += ascii("SmDs") + Data(count: 44)
        return header + u32(UInt32(tags.count)) + table + body
    }

    private static func ascii(_ s: String) -> Data { Data(s.utf8) }
    private static func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    /// s15Fixed16, clamped so a stray value can never trap the Int32 conversion.
    private static func s15(_ v: Double) -> Data {
        let scaled = v.isFinite ? min(max((v * 65536).rounded(), Double(Int32.min)), Double(Int32.max)) : 0
        return u32(UInt32(bitPattern: Int32(scaled)))
    }

    private static func xyzType(_ v: [Double]) -> Data { ascii("XYZ ") + u32(0) + s15(v[0]) + s15(v[1]) + s15(v[2]) }
    private static func sf32(_ m: [Double]) -> Data { m.reduce(ascii("sf32") + u32(0)) { $0 + s15($1) } }
    private static func text(_ s: String) -> Data { ascii("text") + u32(0) + ascii(s) + Data([0]) }

    private static func curve(_ gamma: Double) -> Data {
        ascii("curv") + u32(0) + u32(1) + u16(UInt16((gamma * 256).rounded())) + Data(count: 2)
    }

    /// v2 textDescriptionType, ASCII only.
    private static func textDescription(_ s: String) -> Data {
        let chars = Data(s.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }) + Data([0])
        return ascii("desc") + u32(0) + u32(UInt32(chars.count)) + chars + u32(0) + u32(0) + u16(0) + Data(count: 68)
    }

    /// Apple vcgt, formula form: per channel gamma 1, min 0, max = scale.
    private static func vcgtFormula(_ scales: [Double]) -> Data {
        scales.reduce(ascii("vcgt") + u32(0) + u32(1)) { $0 + s15(1) + s15(0) + s15($1) }
    }
}

// MARK: - ColorSync

/// White point choices offered for an external monitor.
enum WhiteTarget: String, CaseIterable {
    case d65, k6000, k5500, native

    var point: XY? {
        switch self {
        case .d65: return .d65
        case .k6000: return .daylight(kelvin: 6000)
        case .k5500: return .daylight(kelvin: 5500)
        case .native: return nil
        }
    }

    var fileTag: String {
        switch self {
        case .d65: return "D65"
        case .k6000: return "6000K"
        case .k5500: return "5500K"
        case .native: return "Native"
        }
    }

    var title: String {
        switch self {
        case .d65: return L("Like a MacBook without True Tone (D65, 6500K)")
        case .k6000: return L("Warmer, closer to True Tone (6000K)")
        case .k5500: return L("Even Warmer (5500K)")
        case .native: return L("Monitor's Native White, No Correction")
        }
    }
}

enum ColorProfiles {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/ColorSync/Profiles/SmoothDisplay", isDirectory: true)

    private static func info(_ display: ExternalDisplay) -> (CFUUID, [String: Any])? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue(),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?
                  .takeRetainedValue() as? [String: Any] else { return nil }
        return (uuid, info)
    }

    private static func url(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    /// The profile macOS built from the monitor's EDID.
    static func factoryURL(_ display: ExternalDisplay) -> URL? {
        guard let factory = info(display)?.1["FactoryProfiles"] as? [String: Any] else { return nil }
        let id = "\(factory["DeviceDefaultProfileID"] ?? 1)"
        return url((factory[id] as? [String: Any])?["DeviceProfileURL"])
    }

    /// The profile in effect: the user's choice, or the factory one.
    static func currentURL(_ display: ExternalDisplay) -> URL? {
        if let custom = info(display)?.1["CustomProfiles"] as? [String: Any], let first = custom.values.first {
            return url(first)
        }
        return factoryURL(display)
    }

    static func name(of url: URL) -> String {
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(),
              let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String? else {
            return url.deletingPathExtension().lastPathComponent
        }
        return name
    }

    /// Real primaries of the panel, taken from the EDID-based factory profile.
    static func panelGamut(_ display: ExternalDisplay) -> Gamut? {
        guard let url = factoryURL(display), let data = try? Data(contentsOf: url) else { return nil }
        return ICC.gamut(from: data)
    }

    static func profileURL(_ display: ExternalDisplay, _ target: WhiteTarget) -> URL {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let model = String(display.name.replacingOccurrences(of: " ", with: "-").filter(allowed.contains).prefix(60))
        return folder.appendingPathComponent("SmoothDisplay-\(model)-\(target.fileTag).icc")
    }

    /// Writes the profile for `target` (only when its content changed) and returns its location.
    static func generate(_ display: ExternalDisplay, _ target: WhiteTarget) throws -> URL {
        guard let panel = panelGamut(display) else {
            throw NSError(domain: "SmoothDisplay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L("Couldn't read the monitor's factory color profile.")])
        }
        let url = profileURL(display, target)
        let data = ICC.profile(name: "\(display.name) \(target.fileTag) (SmoothDisplay)", panel: panel, white: target.point)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? Data(contentsOf: url))?.dropFirst(36) != data.dropFirst(36) { // ignore the creation date
            try data.write(to: url)
        }
        return url
    }

    /// Assigns a profile to the display; `nil` returns it to the factory profile.
    @discardableResult
    static func assign(_ profile: URL?, to display: ExternalDisplay) -> Bool {
        guard let (uuid, info) = info(display),
              let factory = info["FactoryProfiles"] as? [String: Any] else { return false }
        let id = "\(factory["DeviceDefaultProfileID"] ?? 1)"
        let value: Any = profile.map { $0 as CFURL } ?? kCFNull as Any
        let settings: [String: Any] = [
            id: value,
            kColorSyncProfileUserScope.takeUnretainedValue() as String: kCFPreferencesCurrentUser,
        ]
        return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, settings as CFDictionary)
    }
}
