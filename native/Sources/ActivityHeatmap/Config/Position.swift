import Foundation

/// Persists the widget's dragged position, mirroring the Übersicht
/// version's `position.json` (`{"x":Int,"y":Int}`, an offset added on top
/// of the default top:40/left:40 anchor – see `index.jsx`
/// `loadPosition`/`savePosition`). `x` moves right, `y` moves *down*
/// (screen/CSS convention), which is why `DesktopWindowController`
/// converts it to Cocoa's bottom-left-origin coordinate space.
enum PositionStore {
    struct Offset: Codable {
        var x: Int
        var y: Int
    }

    static var defaultURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ActivityHeatmap/position.json")
    }

    /// `{0,0}` (i.e. "no saved offset yet") on any read failure – matches
    /// the JS version swallowing a missing/malformed file.
    static func load(url: URL = defaultURL) -> Offset {
        guard let data = try? Data(contentsOf: url),
              let offset = try? JSONDecoder().decode(Offset.self, from: data) else {
            return Offset(x: 0, y: 0)
        }
        return offset
    }

    /// Best-effort, synchronous, atomic-ish write (small file, no
    /// history to protect – unlike `Store`, losing this just resets the
    /// widget to its default position).
    static func save(_ offset: Offset, url: URL = defaultURL) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(offset)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-fatal: the widget just stays at its current position
            // in memory; nothing user-visible breaks.
        }
    }
}
