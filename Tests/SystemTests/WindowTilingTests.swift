import CoreGraphics
import KeyshiftCore
@testable import KeyshiftSystem
import XCTest

final class WindowTilingTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 800)
    private let current = CGRect(x: 100, y: 100, width: 600, height: 400)

    private func frame(_ action: SystemAction, in rect: CGRect, current: CGRect? = nil) -> CGRect? {
        WindowTiling.targetFrame(for: action, visible: rect, current: current ?? self.current)
    }

    func testHalvesAndMaximizeOfAVisibleFrameBelowTheMenuBar() {
        XCTAssertEqual(frame(.tileLeft, in: visible), CGRect(x: 0, y: 25, width: 720, height: 800))
        XCTAssertEqual(frame(.tileRight, in: visible), CGRect(x: 720, y: 25, width: 720, height: 800))
        XCTAssertEqual(frame(.tileTop, in: visible), CGRect(x: 0, y: 25, width: 1440, height: 400))
        XCTAssertEqual(frame(.tileBottom, in: visible), CGRect(x: 0, y: 425, width: 1440, height: 400))
        XCTAssertEqual(frame(.maximize, in: visible), visible)
    }

    func testOddSizesLeaveNoGapAndNoOverlap() {
        let odd = CGRect(x: 10, y: 33, width: 1001, height: 701)
        let left = frame(.tileLeft, in: odd)!, right = frame(.tileRight, in: odd)!
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(right.maxX, odd.maxX)
        let top = frame(.tileTop, in: odd)!, bottom = frame(.tileBottom, in: odd)!
        XCTAssertEqual(top.maxY, bottom.minY)
        XCTAssertEqual(bottom.maxY, odd.maxY)
    }

    func testNonZeroOriginSecondaryScreenAbovePrimary() {
        // A display stacked above the primary has negative y in Accessibility coordinates.
        let above = CGRect(x: -200, y: -1055, width: 1920, height: 1030)
        XCTAssertEqual(frame(.tileRight, in: above), CGRect(x: 760, y: -1055, width: 960, height: 1030))
        XCTAssertEqual(frame(.tileBottom, in: above), CGRect(x: -200, y: -540, width: 1920, height: 515))
    }

    func testCenterKeepsSizeAndClampsToTheVisibleFrame() {
        XCTAssertEqual(frame(.center, in: visible), CGRect(x: 420, y: 225, width: 600, height: 400))
        let huge = CGRect(x: 0, y: 0, width: 5000, height: 4000)
        XCTAssertEqual(frame(.center, in: visible, current: huge), visible)
        let shifted = CGRect(x: 1440, y: 0, width: 1000, height: 600)
        XCTAssertEqual(frame(.center, in: shifted, current: CGRect(x: 0, y: 0, width: 400, height: 200)),
                       CGRect(x: 1740, y: 200, width: 400, height: 200))
    }

    func testNonWindowActionsHaveNoFrame() {
        XCTAssertNil(frame(.launchpad, in: visible))
        XCTAssertNil(frame(.lockScreen, in: visible))
    }

    func testCocoaToAccessibilityConversionFlipsOnThePrimaryHeight() {
        // Primary 1440x900 with a 25 pt menu bar and a 70 pt Dock: Cocoa visible = (0,70,1440,805).
        let primary = WindowTiling.accessibilityRect(fromCocoa: CGRect(x: 0, y: 70, width: 1440, height: 805), primaryHeight: 900)
        XCTAssertEqual(primary, CGRect(x: 0, y: 25, width: 1440, height: 805))
        // A display to the right and raised 300 pt: Cocoa y=300..1380 → AX y=-480..600.
        let right = WindowTiling.accessibilityRect(fromCocoa: CGRect(x: 1440, y: 300, width: 1920, height: 1080), primaryHeight: 900)
        XCTAssertEqual(right, CGRect(x: 1440, y: -480, width: 1920, height: 1080))
        // A display below the primary has y beyond the primary's height.
        let below = WindowTiling.accessibilityRect(fromCocoa: CGRect(x: 0, y: -1080, width: 1920, height: 1080), primaryHeight: 900)
        XCTAssertEqual(below, CGRect(x: 0, y: 900, width: 1920, height: 1080))
    }

    func testScreenChoiceFollowsLargestOverlapThenNearestCenter() {
        let main = WindowTiling.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 805))
        let side = WindowTiling.Screen(frame: CGRect(x: 1440, y: -480, width: 1920, height: 1080),
                                       visibleFrame: CGRect(x: 1440, y: -455, width: 1920, height: 1055))
        let screens = [main, side]
        XCTAssertEqual(WindowTiling.screen(for: CGRect(x: 1300, y: 100, width: 400, height: 300), in: screens), side)
        XCTAssertEqual(WindowTiling.screen(for: CGRect(x: 1000, y: 100, width: 400, height: 300), in: screens), main)
        XCTAssertEqual(WindowTiling.screen(for: CGRect(x: 5000, y: 0, width: 100, height: 100), in: screens), side)
        XCTAssertEqual(WindowTiling.screen(for: CGRect(x: -900, y: 2000, width: 100, height: 100), in: screens), main)
        XCTAssertNil(WindowTiling.screen(for: current, in: []))
    }
}
