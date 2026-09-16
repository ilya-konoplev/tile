import Foundation

/// Half-open time interval `[start, end)` expressed as Unix timestamps
/// (seconds, `Double` to match `Date.timeIntervalSince1970`).
///
/// Port of the interval algebra in the Python prototype's `aggregate.py`
/// (`merge` / `subtract` / `intersect` / `awake_duration`). All four
/// functions are pure and treat their inputs as unordered, unmerged bags of
/// intervals – callers never need to pre-sort anything.
enum Intervals {
    typealias Interval = (start: Double, end: Double)

    /// Union of possibly overlapping intervals – avoids double counting.
    /// Sorts its input, so caller order does not matter.
    static func merge(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var out: [Interval] = []
        for (start, end) in sorted {
            if var last = out.last, start <= last.end {
                last.end = Swift.max(last.end, end)
                out[out.count - 1] = last
            } else {
                out.append((start, end))
            }
        }
        return out
    }

    /// Remove `holes` (e.g. screen-locked windows) from `intervals`.
    ///
    /// `intervals` is expected to already be merged (sorted, non-overlapping)
    /// – same contract as the Python original. `holes` does NOT need to be
    /// pre-sorted or pre-merged: this function merges it itself. (The Python
    /// reference has a comment claiming the sweep "relies on holes being
    /// sorted and disjoint" and calls `merge(holes)` first – so it already
    /// does the right thing; the risk is only for a port that drops that
    /// call. We keep the call explicit here for the same reason.)
    static func subtract(_ intervals: [Interval], _ holes: [Interval]) -> [Interval] {
        let mergedHoles = merge(holes)
        var result: [Interval] = []
        for (start, end) in intervals {
            var cursor = start
            for (holeStart, holeEnd) in mergedHoles {
                if holeEnd <= cursor || holeStart >= end {
                    continue
                }
                if holeStart > cursor {
                    result.append((cursor, holeStart))
                }
                cursor = Swift.max(cursor, holeEnd)
                if cursor >= end {
                    break
                }
            }
            if cursor < end {
                result.append((cursor, end))
            }
        }
        return result
    }

    /// Overlap between two interval lists – e.g. a domain and its browser's
    /// foreground time. Merges both inputs first.
    static func intersect(_ a: [Interval], _ b: [Interval]) -> [Interval] {
        let ma = merge(a)
        let mb = merge(b)
        var out: [Interval] = []
        var i = 0, j = 0
        while i < ma.count && j < mb.count {
            let start = Swift.max(ma[i].start, mb[j].start)
            let end = Swift.min(ma[i].end, mb[j].end)
            if start < end {
                out.append((start, end))
            }
            if ma[i].end < mb[j].end {
                i += 1
            } else {
                j += 1
            }
        }
        return out
    }

    /// Seconds of activity that happened while the screen was actually
    /// unlocked.
    static func awakeDuration(_ intervals: [Interval], _ locked: [Interval]) -> Double {
        subtract(merge(intervals), locked).reduce(0) { $0 + ($1.end - $1.start) }
    }
}
