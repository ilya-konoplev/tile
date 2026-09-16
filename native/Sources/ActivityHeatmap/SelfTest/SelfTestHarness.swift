import Foundation

/// Minimal hand-rolled test harness.
///
/// This machine only has the Command Line Tools installed (no full Xcode),
/// and `xcrun --find xctest` fails – confirmed while wiring this up:
/// `SwiftPM` test targets fail to build with `error: no such module
/// 'XCTest'`. ARCHITECTURE.md already established the CLT-only constraint for
/// the app itself (SwiftUI/AppKit/SQLite3 build fine under CLT); it turns
/// out XCTest specifically is the piece that needs full Xcode. Rather than
/// install Xcode (out of scope, and "ничего не устанавливать глобально без
/// согласования"), tests live inside the normal executable target and run
/// via `swift run ActivityHeatmap --self-test`, guarded before any AppKit
/// setup in main.swift.
enum SelfTest {
    struct Failure {
        let message: String
        let location: String
    }

    private static var failures: [Failure] = []
    private static var passCount = 0
    private static var skips: [String] = []
    private static var currentSuite = ""

    static func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        body()
    }

    /// Marks a suite as not-run rather than failed. Only for checks that need
    /// something optional from outside this project – the app must build and
    /// test standalone, so a missing optional extra cannot be a red test.
    static func skip(_ reason: String) {
        skips.append("[\(currentSuite)] \(reason)")
    }

    static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String = "",
        file: String = #fileID,
        line: Int = #line
    ) {
        if condition() {
            passCount += 1
        } else {
            let msg = message()
            failures.append(Failure(
                message: "[\(currentSuite)] \(msg.isEmpty ? "assertion failed" : msg)",
                location: "\(file):\(line)"
            ))
        }
    }

    static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String = "", file: String = #fileID, line: Int = #line) {
        expect(a == b, "\(label.isEmpty ? "" : "\(label): ")expected \(b), got \(a)", file: file, line: line)
    }

    static func expectClose(_ a: Double, _ b: Double, tol: Double = 1e-6, label: String = "", file: String = #fileID, line: Int = #line) {
        expect(abs(a - b) <= tol, "\(label.isEmpty ? "" : "\(label): ")expected \(b) ± \(tol), got \(a) (Δ\(abs(a - b)))", file: file, line: line)
    }

    /// Runs every registered suite and prints a summary. Returns the
    /// process exit code (0 on all-pass).
    static func runAll() -> Int32 {
        failures = []
        passCount = 0
        skips = []

        IntervalsTests.run()
        PaletteTests.run()
        AggregatorTests.run()
        CatalogTests.run()
        StoreTests.run()
        CrossValidationTests.run()
        LocalizationTests.run()
        SettingsCompatTests.run()
        SettingsStoreTests.run()
        BalanceTests.run()
        HistoryFileTests.run()
        HeatmapLayoutTests.run()


        let skipNote = skips.isEmpty ? "" : ", \(skips.count) skipped"
        print("--- SelfTest: \(passCount) passed, \(failures.count) failed\(skipNote) ---")
        for f in failures {
            print("FAIL \(f.location): \(f.message)")
        }
        for s in skips {
            print("SKIP \(s)")
        }
        return failures.isEmpty ? 0 : 1
    }
}
