import AppKit
import XCTest
@testable import ThoughtStream

final class SidebarAppearanceTests: XCTestCase {
    @MainActor
    func testSidebarCornersAndAccessLabelInBothAppearances() throws {
        let previousStyle = InterfaceStyle.current
        InterfaceStyle.current = .breathe
        defer { InterfaceStyle.current = previousStyle }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = Session(project: root, title: "Sidebar appearance", storageRoot: root)
        session.report(.user, "Check the sidebar corners and access label.")
        let workspace = WorkspaceWindow(restoredSessions: [session],
                                        stateStore: WorkspaceStateStore(url: root.appendingPathComponent("workspace.json")))
        let window = try XCTUnwrap(workspace.window)
        defer { workspace.stopAll(); window.close(); try? FileManager.default.removeItem(at: root) }
        window.setContentSize(NSSize(width: 1120, height: 800))
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let surface = try XCTUnwrap(descendants(content).compactMap { $0 as? SidebarSurface }.first)
        let container = try XCTUnwrap(surface.superview)
        let access = try XCTUnwrap(descendants(surface).compactMap { $0 as? NSButton }.first {
            $0.toolTip?.hasPrefix("Change permissions") == true
        })
        access.title = "Full access · no approvals"
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            XCTAssertEqual(surface.frame, container.bounds.insetBy(dx: SidebarSurface.inset, dy: SidebarSurface.inset))
            XCTAssertEqual(surface.layer?.cornerRadius, SidebarSurface.radius)
            XCTAssertEqual(surface.layer?.masksToBounds, true)
            XCTAssertNil(surface.layer?.mask)
            XCTAssertTrue(access.isEnabled)
            XCTAssertNotNil(access.action)

            for highlighted in [false, true] {
                access.highlight(highlighted)
                let bitmap = try XCTUnwrap(access.bitmapImageRepForCachingDisplay(in: access.bounds))
                access.cacheDisplay(in: access.bounds, to: bitmap)
                var coloredPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                        if color.blueComponent - color.redComponent > 0.08 { coloredPixels += 1 }
                    }
                }
                XCTAssertEqual(coloredPixels, 0, "The access label should stay neutral, including while pressed")
            }
            access.highlight(false)
            if let directory = ProcessInfo.processInfo.environment["THOUGHTSTREAM_SIDEBAR_PREVIEW"] {
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("sidebar-\(appearance.rawValue).png"))
            }
        }
    }
}
