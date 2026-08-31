import AppKit
import XCTest
@testable import Inklet

@MainActor
final class UpdateCheckMenuTests: XCTestCase {
    func testManagedUpdateMenuKeepsExplicitlyDisabledItemDisabledAfterAppKitUpdate() {
        _ = NSApplication.shared
        let target = MenuActionTarget()
        let menu = NSMenu()
        UpdateCheckMenuConfiguration.apply(to: menu)
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(MenuActionTarget.checkForUpdates),
            keyEquivalent: ""
        )
        item.target = target
        menu.addItem(item)

        item.isEnabled = false
        menu.update()

        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertFalse(item.isEnabled)
    }
}

@MainActor
private final class MenuActionTarget: NSObject {
    @objc func checkForUpdates() {}
}
