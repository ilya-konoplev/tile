import Foundation

enum IntervalsTests {
    private static func iv(_ pairs: [(Double, Double)]) -> [Intervals.Interval] {
        pairs.map { ($0.0, $0.1) }
    }

    private static func assertEqual(_ a: [Intervals.Interval], _ b: [(Double, Double)], _ label: String) {
        SelfTest.expectEqual(a.count, b.count, "\(label) count")
        for (x, y) in zip(a, b) {
            SelfTest.expectClose(x.start, y.0, label: "\(label) start")
            SelfTest.expectClose(x.end, y.1, label: "\(label) end")
        }
    }

    static func run() {
        SelfTest.suite("Intervals") {
            // merge
            assertEqual(Intervals.merge(iv([(0, 10), (5, 15)])), [(0, 15)], "merge overlap")
            assertEqual(Intervals.merge(iv([(0, 20), (5, 10)])), [(0, 20)], "merge nesting")
            assertEqual(Intervals.merge(iv([(0, 10), (10, 20)])), [(0, 20)], "merge touching")
            assertEqual(Intervals.merge(iv([(20, 30), (0, 10), (10, 20)])), [(0, 30)], "merge unsorted input")
            assertEqual(Intervals.merge(iv([(0, 5), (10, 15)])), [(0, 5), (10, 15)], "merge disjoint")
            assertEqual(Intervals.merge([]), [], "merge empty")

            // subtract
            assertEqual(Intervals.subtract(iv([(0, 10)]), iv([(0, 3)])), [(3, 10)], "subtract hole at start")
            assertEqual(Intervals.subtract(iv([(0, 10)]), iv([(7, 10)])), [(0, 7)], "subtract hole at end")
            assertEqual(Intervals.subtract(iv([(0, 10)]), iv([(4, 6)])), [(0, 4), (6, 10)], "subtract hole in middle")
            assertEqual(Intervals.subtract(iv([(4, 6)]), iv([(0, 10)])), [], "subtract hole larger than interval")
            assertEqual(Intervals.subtract(iv([(0, 10)]), []), [(0, 10)], "subtract empty holes")
            assertEqual(Intervals.subtract([], iv([(0, 10)])), [], "subtract empty intervals")
            // Regression: the Python reference's sweep relies on holes being
            // sorted/disjoint and calls merge(holes) first specifically for
            // that reason. Feed unsorted, overlapping holes to make sure our
            // port also sorts/merges internally.
            assertEqual(
                Intervals.subtract(iv([(0, 100)]), iv([(50, 60), (10, 20), (15, 25)])),
                [(0, 10), (25, 50), (60, 100)],
                "subtract unsorted overlapping holes"
            )
            assertEqual(
                Intervals.subtract(iv([(0, 10), (20, 30)]), iv([(5, 8), (22, 24)])),
                [(0, 5), (8, 10), (20, 22), (24, 30)],
                "subtract multiple holes across multiple intervals"
            )

            // intersect
            assertEqual(Intervals.intersect(iv([(0, 10)]), iv([(5, 15)])), [(5, 10)], "intersect overlap")
            assertEqual(Intervals.intersect(iv([(0, 5)]), iv([(10, 15)])), [], "intersect no overlap")
            assertEqual(Intervals.intersect(iv([(0, 5), (10, 15)]), iv([(2, 12)])), [(2, 5), (10, 12)], "intersect multiple segments")

            // awakeDuration
            SelfTest.expectClose(Intervals.awakeDuration(iv([(0, 100)]), iv([(20, 30)])), 90, label: "awakeDuration subtracts locked")
            SelfTest.expectClose(Intervals.awakeDuration(iv([(0, 10), (5, 15)]), []), 15, label: "awakeDuration merges overlap first (not naive sum 20)")
            SelfTest.expectClose(Intervals.awakeDuration([], []), 0, label: "awakeDuration empty input")
        }
    }
}
