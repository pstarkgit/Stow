import AppKit
import CoreGraphics
import Foundation

/// The two views of the menu bar the rest of the app reads.
///
/// These lived on `ItemMover` while Stow still synthesised Command-drags. The mover is gone;
/// the scans stayed because everything that decides what is hidden reads one of them.
@MainActor
enum BarItems {

    /// Every menu bar item genuinely SITTING in the bar, left to right.
    ///
    /// `isOnScreen` alone is not enough, and relying on it was a real defect. It means the frame
    /// INTERSECTS the bar rect, and an expanded seam does: measured on a live bar, Stow's own seam
    /// spanned x-3862 to x1154 at 5016pt wide, passed the filter, and was then offered as a
    /// neighbour. So an item also has to START inside the bar and be of plausible item width.
    static func onBar() -> [ObservedItem] {
        guard let screen = NSScreen.main else { return [] }
        let bar = BarScanner.menuBarRect(for: screen)
        return BarScanner.scan(menuBarRect: bar)
            .items
            .filter(\.isOnScreen)
            .filter { $0.frame.minX >= bar.minX }
            .filter { $0.frame.width <= maximumPlausibleItemWidth }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Every item with a real window in the menu bar band, including the ones the seam has
    /// pushed off the left edge. Zero-width placeholders are dropped; position is not filtered.
    static func positionable() -> [ObservedItem] {
        BarScanner.scan(menuBarRect: NSScreen.main.map { BarScanner.menuBarRect(for: $0) } ?? .zero)
            .items
            .filter { $0.frame.width > 0 }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Widest a real menu bar item is taken to be. The clock with a date is the widest genuine
    /// item measured at 165pt; a pushing seam is about 5,000pt.
    static let maximumPlausibleItemWidth: CGFloat = 400
}

/// One append-only log for everything that changes the bar.
///
/// One file, not several, because the paths interleave on a real bar: a reveal happening
/// between two launch checks is exactly the sequence worth reading in order.
enum StowLog {
    /// Appends one line, newline included so a caller cannot forget it.
    ///
    /// Failure is ignored on purpose: a diagnostic log that can break the thing it observes is
    /// worse than no log.
    nonisolated static func append(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Stow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("arrange.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
