import Foundation

enum PaletteTests {
    static func run() {
        SelfTest.suite("Palette") {
            // hue/chroma against values printed by the Python reference
            // (hex_to_hue_chroma in aggregate.py) for the exact inputs
            // quoted in ARCHITECTURE.md.
            do {
                let hc = try! Palette.hexToHueChroma("#9974f7")
                SelfTest.expectClose(hc.hue, 293.6, tol: 0.1, label: "#9974f7 hue")
            }
            do {
                let hc = try! Palette.hexToHueChroma("#10b981")
                SelfTest.expectClose(hc.hue, 162.5, tol: 0.1, label: "#10b981 hue")
            }
            do {
                let hc = try! Palette.hexToHueChroma("#3b82f6")
                SelfTest.expectClose(hc.hue, 259.8, tol: 0.1, label: "#3b82f6 hue")
            }
            do {
                let hc = try! Palette.hexToHueChroma("#a855f7")
                SelfTest.expectClose(hc.hue, 303.9, tol: 0.1, label: "#a855f7 hue")
            }

            // The brand accent returns the designer's hand-picked ramp
            // verbatim, NOT the generated one – see Palette.designRamp for why
            // (the generator's gamut clipping desaturates it visibly).
            let (accent, ramp) = Palette.ramp(forAccent: "#9974f7")
            SelfTest.expectEqual(accent, "#9974f7", "accent passthrough")
            SelfTest.expectEqual(ramp, Palette.designRamp, "brand accent uses the design ramp")
            SelfTest.expectEqual(Palette.ramp(forAccent: "#9974F7").ramp, Palette.designRamp,
                                 "brand match is case-insensitive")

            // The generator itself is unchanged and still cross-validates
            // against the Python reference for every non-brand accent.
            SelfTest.expectEqual(
                Palette.ramp(forAccent: "#10b981").ramp,
                ["#e0f4e9", "#9ae4c0", "#51c795", "#009f6d", "#006f4c"],
                "generated ramp for a non-brand accent"
            )

            // Roundtrip: build a colour exactly on the ramp curve via
            // oklchToHex, re-derive hue/chroma from its hex, rebuild –
            // must reproduce the same hex exactly.
            let hue = 293.56487683208945
            let chroma = 0.09
            let lightness = 0.86
            let hex = Palette.oklchToHex(lightness: lightness, chroma: chroma, hue: hue)
            let hc = try! Palette.hexToHueChroma(hex)
            let rebuilt = Palette.oklchToHex(lightness: lightness, chroma: hc.chroma, hue: hc.hue)
            SelfTest.expectEqual(hex, rebuilt, "hex->oklch->hex roundtrip")

            // Achromatic accents share the same grey ramp.
            let white = Palette.ramp(forAccent: "#ffffff").ramp
            let black = Palette.ramp(forAccent: "#000000").ramp
            let grey = Palette.ramp(forAccent: "#808080").ramp
            SelfTest.expectEqual(white, ["#eeeeee", "#d1d1d1", "#aeaeae", "#868686", "#5d5d5d"], "white ramp")
            SelfTest.expectEqual(white, black, "white == black ramp")
            SelfTest.expectEqual(white, grey, "white == grey ramp")

            // Malformed / empty accent falls back to #9974f7.
            let (fbAccent, fbRamp) = Palette.ramp(forAccent: "not-a-color")
            SelfTest.expectEqual(fbAccent, Palette.fallbackAccent, "malformed accent falls back")
            SelfTest.expectEqual(fbRamp, Palette.designRamp, "fallback ramp matches brand ramp")
            SelfTest.expectEqual(Palette.ramp(forAccent: "").accent, Palette.fallbackAccent, "empty accent falls back")

            // 3-digit hex expands like 6-digit.
            let a = try! Palette.hexToHueChroma("#fff")
            let b = try! Palette.hexToHueChroma("#ffffff")
            SelfTest.expectClose(a.hue, b.hue, label: "#fff == #ffffff hue")
            SelfTest.expectClose(a.chroma, b.chroma, label: "#fff == #ffffff chroma")
        }
    }
}
