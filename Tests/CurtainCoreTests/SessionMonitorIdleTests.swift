import CoreGraphics
import XCTest

@testable import CurtainCore

/// Regression: idle time must be measured against kCGAnyInputEventType (~0). The
/// previous `.null` (0) returned ~22 hours on a live Mac, so the idle latch never
/// armed and idle disconnect/lock/screen-off never fired.
final class SessionMonitorIdleTests: XCTestCase {
    func testIdleUsesAnyInputEventType() {
        XCTAssertEqual(SessionMonitor.anyInputEventType.rawValue, ~UInt32(0))
        XCTAssertNotEqual(SessionMonitor.anyInputEventType, .null)
    }
}
