import Foundation

/// Differential test against a second, independent implementation of the
/// same aggregation rules: builds a synthetic knowledgeC.db covering every
/// edge case in ARCHITECTURE.md's algorithm section, runs both engines over
/// it and diffs the resulting day-by-day JSON field by field.
///
/// The second engine is the original Python prototype this app grew out of
/// (`aggregate.py`), executed as-is via `python3` – real cross-process
/// validation, not the same logic rewritten twice.
///
/// It is an OPTIONAL extra. The app is standalone and must build and test
/// without the prototype present, so a missing `aggregate.py` SKIPS this
/// suite instead of failing it. Everything the cross-check covers is also
/// covered by `AggregatorTests` on its own.
enum CrossValidationTests {
    static func run() {
        SelfTest.suite("CrossValidation") {
            guard let widgetDir = findWidgetDir(),
                  FileManager.default.fileExists(atPath: widgetDir + "/aggregate.py") else {
                SelfTest.skip("Python reference (aggregate.py) not present – cross-check not run")
                return
            }

            let scenario = Fixtures.build()
            var dbPath: String?
            do {
                dbPath = try SyntheticKnowledgeDB.build(rows: scenario.events.map { $0.toSyntheticRow() })
            } catch {
                SelfTest.expect(false, "failed to build synthetic DB: \(error)")
                return
            }
            guard let dbPath else { return }
            defer { try? FileManager.default.removeItem(atPath: dbPath) }

            // --- Swift engine ---
            let usage = scenario.events.compactMap { $0.toUsageRow(calendar: scenario.calendar) }
            let locked = scenario.events.compactMap { $0.toLockedRow() }
            let swiftDays = Aggregator.collect(usage: usage, locked: locked, settings: scenario.settings, calendar: scenario.calendar)

            // Sanity: also exercise Knowledge.loadRows itself (copy-aside +
            // real SQL, not the hand-built UsageRow array) against the same
            // synthetic file, and confirm it yields the same result. This is
            // what actually proves Knowledge.swift's queries are correct,
            // not just Aggregator's in-memory logic.
            do {
                let cutoff = Date().addingTimeInterval(-91 * 86400).timeIntervalSince1970 - Knowledge.coreDataEpoch
                let (loadedUsage, loadedLocked) = try Knowledge.loadRows(dbPath: dbPath, cutoff: cutoff)
                let viaKnowledge = Aggregator.collect(usage: loadedUsage, locked: loadedLocked, settings: scenario.settings, calendar: scenario.calendar)
                SelfTest.expect(daysEqual(viaKnowledge, swiftDays), "Knowledge.loadRows(dbPath:) result must match the hand-built UsageRow fixture – got \(viaKnowledge) vs \(swiftDays)")
            } catch {
                SelfTest.expect(false, "Knowledge.loadRows threw against synthetic DB: \(error)")
            }

            // --- Python reference engine ---
            guard let pythonJSON = runPythonReference(widgetDir: widgetDir, dbPath: dbPath, scenario: scenario) else {
                SelfTest.expect(false, "python3 reference run failed or produced no output – see stderr above")
                return
            }

            compare(swift: swiftDays, python: pythonJSON, scenario: scenario)
        }
    }

    /// Locates the Python prototype, which lives outside this project and is
    /// optional. Several candidate layouts are tried rather than one hardcoded
    /// path: the prototype has already been moved once (from the project root
    /// into `ubersicht-prototype/`), and a stale single path would not fail
    /// loudly here – it would silently downgrade the cross-check to "skipped"
    /// and quietly cost the coverage it exists for.
    private static func findWidgetDir() -> String? {
        // .../native/Sources/ActivityHeatmap/SelfTest/CrossValidationTests.swift
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() } // -> "native"
        root.deleteLastPathComponent()                    // -> project root

        let candidates = [
            "ubersicht-prototype/activity-heatmap.widget",
            "activity-heatmap.widget",
        ]
        for candidate in candidates {
            let path = root.appendingPathComponent(candidate).path
            if FileManager.default.fileExists(atPath: path + "/aggregate.py") {
                return path
            }
        }
        return nil
    }

    private static func runPythonReference(widgetDir: String, dbPath: String, scenario: Fixtures.Scenario) -> [String: Any]? {
        let cfgJSON: [String: Any] = [
            "mode": scenario.settings.mode.rawValue,
            "apps": ["allow": scenario.settings.apps.allow, "deny": scenario.settings.apps.deny],
            "sites": ["allow": scenario.settings.sites.allow, "deny": scenario.settings.sites.deny],
            "names": scenario.settings.names,
            "minSeconds": scenario.settings.minSeconds,
        ]
        guard let cfgData = try? JSONSerialization.data(withJSONObject: cfgJSON),
              let cfgLiteral = String(data: cfgData, encoding: .utf8) else { return nil }

        let script = """
        import sys, json
        sys.path.insert(0, \(pyString(widgetDir)))
        import aggregate
        aggregate.DB_PATH = \(pyString(dbPath))
        cfg = json.loads(\(pyString(cfgLiteral)))
        print(json.dumps(aggregate.collect(cfg)))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("CrossValidation: failed to launch python3: \(error)")
            return nil
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            print("CrossValidation: python3 exited \(process.terminationStatus): \(String(data: errData, encoding: .utf8) ?? "")")
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            print("CrossValidation: could not parse python output: \(String(data: outData, encoding: .utf8) ?? "")")
            return nil
        }
        return obj
    }

    private static func pyString(_ s: String) -> String {
        // JSON string literals are valid Python string literals too – EXCEPT
        // that JSONSerialization escapes "/" as "\/", which JSON accepts but
        // Python treats as an invalid escape and (found by running this)
        // keeps the literal backslash, silently corrupting any path. Ask for
        // .withoutEscapingSlashes to avoid that.
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast()) // strip the wrapping [ ]
    }

    private static func daysEqual(_ a: [String: DayStats], _ b: [String: DayStats]) -> Bool {
        a == b
    }

    private static func compare(swift: [String: DayStats], python: [String: Any], scenario: Fixtures.Scenario) {
        let swiftKeys = Set(swift.keys)
        let pythonKeys = Set(python.keys)
        SelfTest.expectEqual(swiftKeys, pythonKeys, "day keys must match between engines")

        for day in swiftKeys.intersection(pythonKeys) {
            guard let pyDay = python[day] as? [String: Any] else {
                SelfTest.expect(false, "python day \(day) has unexpected shape: \(python[day] ?? "nil")")
                continue
            }
            let swiftDay = swift[day]!
            let pyT = (pyDay["t"] as? NSNumber)?.intValue
            SelfTest.expectEqual(swiftDay.t, pyT ?? -1, "day \(day) total seconds (swift vs python)")

            guard let pyTop = pyDay["top"] as? [[Any]] else {
                SelfTest.expect(false, "python day \(day) top has unexpected shape: \(pyDay["top"] ?? "nil")")
                continue
            }
            let swiftTop = swiftDay.top.map { ($0.name, $0.seconds) }
            let pythonTop = pyTop.compactMap { pair -> (String, Int)? in
                guard pair.count == 2, let name = pair[0] as? String, let sec = (pair[1] as? NSNumber)?.intValue else { return nil }
                return (name, sec)
            }
            SelfTest.expectEqual(swiftTop.map(\.0), pythonTop.map(\.0), "day \(day) top names, in order")
            SelfTest.expectEqual(swiftTop.map(\.1), pythonTop.map(\.1), "day \(day) top seconds, in order")
        }
    }
}
