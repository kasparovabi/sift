import XCTest
import Foundation
@testable import ClaudeOSUI

final class WindowGeometryTests: XCTestCase {
    let content = CGRect(x: 100, y: 200, width: 1000, height: 700)

    func testCanvasToScreenTopLeftMapsToScreenTop() {
        let f = WindowGeometry.screenFrame(canvasOrigin: .zero, size: CGSize(width: 300, height: 180),
                                           contentScreenFrame: content)
        XCTAssertEqual(f.minX, 100, accuracy: 0.01)
        XCTAssertEqual(f.maxY, 900, accuracy: 0.01)
        XCTAssertEqual(f.height, 180, accuracy: 0.01)
    }

    func testRoundTrip() {
        let size = CGSize(width: 320, height: 240)
        let canvas = CGPoint(x: 140, y: 90)
        let screen = WindowGeometry.screenFrame(canvasOrigin: canvas, size: size, contentScreenFrame: content)
        let back = WindowGeometry.canvasOrigin(screenFrame: screen, contentScreenFrame: content)
        XCTAssertEqual(back.x, canvas.x, accuracy: 0.01)
        XCTAssertEqual(back.y, canvas.y, accuracy: 0.01)
    }

    func testClampKeepsWindowInWorkArea() {
        let clamped = WindowGeometry.clampToWorkArea(canvasOrigin: CGPoint(x: 900, y: -50),
                                                     size: CGSize(width: 400, height: 300),
                                                     contentSize: CGSize(width: 1000, height: 700),
                                                     topInset: 28, bottomInset: 80)
        XCTAssertEqual(clamped.y, 28, accuracy: 0.01)
        XCTAssertEqual(clamped.x, 600, accuracy: 0.01)
    }

    func testClampBottomRespectsDock() {
        let clamped = WindowGeometry.clampToWorkArea(canvasOrigin: CGPoint(x: 0, y: 690),
                                                     size: CGSize(width: 200, height: 200),
                                                     contentSize: CGSize(width: 1000, height: 700),
                                                     topInset: 28, bottomInset: 80)
        XCTAssertEqual(clamped.y, 420, accuracy: 0.01)
    }
}
