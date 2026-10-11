import Foundation
import XCTest

/// Removes a test-only UserDefaults suite AND its plist file. `removePersistentDomain` clears the
/// values but cfprefsd leaves (or re-creates) an empty plist in ~/Library/Preferences, which piled up
/// hundreds of files. Names are recorded and the files are swept once the whole test bundle finishes,
/// after cfprefsd has stopped writing.
enum TestDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: Set<String> = []
    nonisolated(unsafe) private static var observer: SweepObserver?

    static func destroy(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        lock.lock()
        names.insert(suiteName)
        if observer == nil {
            let o = SweepObserver()
            observer = o
            XCTestObservationCenter.shared.addTestObserver(o)
        }
        lock.unlock()
        removeFile(suiteName)
    }

    private static func removeFile(_ suiteName: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: url)
    }

    fileprivate static func sweepAll() {
        lock.lock()
        let all = names
        lock.unlock()
        Thread.sleep(forTimeInterval: 2.0)
        for name in all { removeFile(name) }
    }

    private final class SweepObserver: NSObject, XCTestObservation {
        func testBundleDidFinish(_ testBundle: Bundle) { TestDefaults.sweepAll() }
    }
}
