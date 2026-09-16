import Foundation

/// OKLCH colour ramp, ported from `hex_to_hue_chroma` / `oklch_to_hex` /
/// `_ramp_for` / `build_theme` in the Python prototype's `aggregate.py`.
///
/// The heatmap ramp is derived from a single accent colour: take its OKLCH
/// hue, walk a fixed lightness/chroma curve along it. OKLCH keeps the steps
/// evenly spaced perceptually, which plain rgba() opacity steps do not.
/// Output is sRGB hex.
enum Palette {
    static let rampLightness: [Double] = [0.95, 0.86, 0.75, 0.62, 0.48]
    static let rampChroma: [Double] = [0.025, 0.09, 0.13, 0.14, 0.12]
    static let fallbackAccent = "#9974f7"

    struct HueChroma {
        let hue: Double
        let chroma: Double
    }

    enum PaletteError: Error {
        case malformedHex
    }

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// Parse `#rgb` or `#rrggbb` (leading `#` optional) into 0...1 sRGB
    /// components. Throws on anything else (matches Python's `int(x, 16)`
    /// raising `ValueError` on malformed input).
    private static func parseHex(_ value: String) throws -> (r: Double, g: Double, b: Double) {
        var v = value
        if v.hasPrefix("#") { v.removeFirst() }
        if v.count == 3 {
            v = v.map { "\($0)\($0)" }.joined()
        }
        guard v.count == 6, v.allSatisfy({ $0.isHexDigit }) else {
            throw PaletteError.malformedHex
        }
        func component(_ range: Range<String.Index>) -> Double? {
            UInt8(v[range], radix: 16).map { Double($0) / 255 }
        }
        let i0 = v.startIndex
        let i2 = v.index(i0, offsetBy: 2)
        let i4 = v.index(i0, offsetBy: 4)
        let i6 = v.endIndex
        guard let r = component(i0..<i2), let g = component(i2..<i4), let b = component(i4..<i6) else {
            throw PaletteError.malformedHex
        }
        return (r, g, b)
    }

    /// OKLCH hue (degrees, 0..<360) and chroma of an `#rrggbb` colour.
    static func hexToHueChroma(_ value: String) throws -> HueChroma {
        let (rs, gs, bs) = try parseHex(value)
        let r = srgbToLinear(rs), g = srgbToLinear(gs), b = srgbToLinear(bs)
        let l = pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
        let m = pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
        let s = pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var hue = atan2(bb, a) * 180 / .pi
        hue = hue.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let chroma = (a * a + bb * bb).squareRoot()
        return HueChroma(hue: hue, chroma: chroma)
    }

    private static func oklchToRGBLinear(lightness: Double, chroma: Double, hue: Double) -> (Double, Double, Double) {
        let hr = hue * .pi / 180
        let a = chroma * cos(hr)
        let b = chroma * sin(hr)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (r, g, bl)
    }

    /// Binary-search the chroma back into sRGB gamut, then emit as
    /// `#rrggbb`.
    static func oklchToHex(lightness: Double, chroma: Double, hue: Double) -> String {
        var low = 0.0
        var high = chroma
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let (r, g, b) = oklchToRGBLinear(lightness: lightness, chroma: mid, hue: hue)
            let inGamut = [r, g, b].allSatisfy { -1e-4 <= $0 && $0 <= 1 + 1e-4 }
            if inGamut {
                low = mid
            } else {
                high = mid
            }
        }
        let (r, g, b) = oklchToRGBLinear(lightness: lightness, chroma: low, hue: hue)
        func toByte(_ c: Double) -> Int {
            let srgb = linearToSrgb(min(1.0, max(0.0, c)))
            return Int((min(1.0, max(0.0, srgb)) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", toByte(r), toByte(g), toByte(b))
    }

    /// Build the 5-colour ramp for a given accent hue/chroma. An
    /// achromatic accent (chroma < 0.02) renders as an honestly neutral
    /// grey ramp instead of a random hue.
    private static func ramp(hue: Double, chroma: Double) -> [String] {
        let saturation: Double = chroma < 0.02 ? 0.0 : 1.0
        return (0..<5).map { i in
            oklchToHex(lightness: rampLightness[i], chroma: rampChroma[i] * saturation, hue: hue)
        }
    }

    /// A day whose balance is exactly zero – nothing classified yet, or useful
    /// and destructive time that cancelled out. One shared neutral for both
    /// sides, so the middle of the diverging scale is a single colour rather
    /// than two near-identical pales. The design's `zero`.
    static let neutral = "#efedf3"

    /// The diverging scales the design ships (`scales()` in
    /// `Activity Widget.dc.html`), keyed by the accent that selects them.
    ///
    /// These are NOT what the OKLCH generator produces: the generator
    /// binary-searches chroma down into the sRGB gamut and comes out visibly
    /// dusty – for `#9974f7` step 3 lands on `#8b73d2` where the design wants
    /// the brand purple itself, and step 4 on a greyish `#624e9a` instead of a
    /// rich violet. For the colours the design actually names, its hand-picked
    /// values win; the generator still covers any other accent written into
    /// settings.json by hand.
    ///
    /// Each entry holds only the four *coloured* steps. `neutral` is prepended
    /// when the ramp is handed to the view, so index 0 always means "no
    /// balance" and 1...4 are the intensity steps – the same shape the
    /// generated ramps have.
    static let positiveScales: [String: [String]] = [
        "#9974f7": ["#dccbf7", "#bd9df3", "#9974f7", "#6f46c9"],
        "#a855f7": ["#e3ccf7", "#cba3f5", "#a855f7", "#7d34c9"],
        "#5f9df7": ["#cfe0f7", "#a3c5f7", "#5f9df7", "#3b74c9"],
        "#4fc9a8": ["#c9ede2", "#93dcc4", "#4fc9a8", "#2f9377"],
    ]

    static let negativeScales: [String: [String]] = [
        "#e07a3f": ["#f7dcc4", "#f2b586", "#e07a3f", "#b0521d"],
        "#f772c9": ["#f7cde8", "#f7a6d9", "#f772c9", "#c94d9e"],
        "#c94d4d": ["#f5cfcf", "#eda3a3", "#c94d4d", "#963434"],
    ]

    /// The brand ramp: the design's purple scale behind the shared neutral.
    static let designRamp = [neutral] + positiveScales["#9974f7"]!

    /// Accent choices offered in Settings: the ki-school brand colour plus the
    /// four presets the designer put in the mockup's accent picker
    /// (`Activity Widget.dc.html`, `accent` prop options). Any other hex still
    /// works if written into settings.json by hand – these are just the
    /// one-click ones.
    struct Preset {
        let hex: String
        let nameRu: String
        let nameEn: String
    }

    /// The three negative swatches the design offers ("Цвет негативного").
    /// Warm and pink before red: the point is "this pulled you down", not
    /// "error".
    static let badPresets: [Preset] = [
        Preset(hex: "#e07a3f", nameRu: "Оранжевый", nameEn: "Orange"),
        Preset(hex: "#f772c9", nameRu: "Розовый", nameEn: "Pink"),
        Preset(hex: "#c94d4d", nameRu: "Красный", nameEn: "Red"),
    ]

    /// The three positive swatches the design offers ("Цвет полезного").
    static let presets: [Preset] = [
        Preset(hex: "#9974f7", nameRu: "Фиолетовый", nameEn: "Purple"),
        Preset(hex: "#5f9df7", nameRu: "Синий", nameEn: "Blue"),
        Preset(hex: "#4fc9a8", nameRu: "Мятный", nameEn: "Mint"),
    ]

    /// Full 5-step ramp for an accent hex string: the design's own scale when
    /// the accent is one it names, generated from OKLCH hue for anything else,
    /// and a fallback to the brand colour on malformed input.
    static func ramp(forAccent accent: String) -> (accent: String, ramp: [String]) {
        let key = accent.lowercased()
        if let scale = positiveScales[key] ?? negativeScales[key] {
            return (key, [neutral] + scale)
        }
        if let hc = try? hexToHueChroma(accent) {
            return (accent, ramp(hue: hc.hue, chroma: hc.chroma))
        }
        // Malformed accent – fall back to the brand colour, i.e. the design ramp.
        return (fallbackAccent, designRamp)
    }
}
