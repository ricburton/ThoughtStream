import AppKit
import XCTest
@testable import ThoughtStream

final class TabCardMotionTests: XCTestCase {
    func testCardLeansWithTravelThenSettlesLevel() {
        var motion = TabCardMotion(center: .zero)
        motion.target = NSPoint(x: 500, y: 100)
        motion.advance(1.0 / 60)
        XCTAssertGreaterThan(motion.x.value, 0)
        XCTAssertLessThan(motion.roll.value, 0)
        XCTAssertGreaterThan(motion.pitch.value, 0)
        XCTAssertGreaterThan(motion.scale.value, 1)
        for _ in 0..<240 { motion.advance(1.0 / 60) }
        XCTAssertEqual(motion.x.value, 500, accuracy: 0.01)
        XCTAssertEqual(motion.y.value, 100, accuracy: 0.01)
        XCTAssertEqual(motion.roll.value, 0, accuracy: 0.001)
        XCTAssertEqual(motion.scale.value, 1.055, accuracy: 0.001)
    }
    func testFastReversalRemainsGentleAndStable() {
        var motion = TabCardMotion(center: .zero)
        for frame in 0..<120 {
            motion.target = NSPoint(x: frame < 60 ? 4000 : -4000, y: 0)
            motion.advance(1.0 / 60)
            if frame == 70 { XCTAssertGreaterThan(motion.roll.value, 0) }
            XCTAssertTrue(motion.x.value.isFinite)
            XCTAssertLessThan(abs(motion.roll.value), 0.1)
            XCTAssertLessThan(abs(motion.yaw.value), 0.08)
        }
        XCTAssertEqual(motion.roll.value, 0, accuracy: 0.001)
    }
    func testReducedMotionTracksWithoutTiltOrScale() {
        var motion = TabCardMotion(center: .zero)
        motion.target = NSPoint(x: 500, y: 300)
        motion.advance(1.0 / 60, reducedMotion: true)
        XCTAssertEqual(motion.x.value, 500)
        XCTAssertEqual(motion.y.value, 300)
        XCTAssertEqual(motion.roll.value, 0)
        XCTAssertEqual(motion.scale.value, 1)
    }
}
