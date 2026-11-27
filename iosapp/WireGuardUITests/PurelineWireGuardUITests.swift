import XCTest

final class PurelineWireGuardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func test01SimulatorStatusDoesNotPretendToRunVPN() {
        let app = XCUIApplication()
        app.launch()
        let connect = app.buttons["pureline.wg.connect"]
        // The same production components are exercised in the focused host
        // and in the full app's actual Image Filter tab.
        if !connect.waitForExistence(timeout: 3) {
            let imageFilter = app.buttons["Image Filter"].firstMatch
            XCTAssertTrue(imageFilter.waitForExistence(timeout: 20))
            imageFilter.tap()
        }
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        XCTAssertFalse(connect.isEnabled)
        XCTAssertTrue(app.staticTexts["pureline.wg.status"].label.contains("Physical device required for VPN"))
        screenshot("WireGuard-real-simulator-limitation")
        app.terminate()
    }

    @MainActor
    func test02ActualWebKitBrowsesImageGalleries() {
        browse([
            ("allow", 10), ("block", 10), ("mixed", 10),
            ("objects", 9), ("groups", 2), ("thumbnails", 10)
        ])
    }

    @MainActor
    func test04SVGAndHighResolutionImagesRenderThroughFiltering() {
        browse([("svg", 5), ("highres", 4)])
    }

    @MainActor
    private func browse(_ pages: [(String, Int)]) {
        for (name, count) in pages {
            let app = XCUIApplication()
            app.launchArguments = ["-purelineLab", "YES", "-purelineLabURL", "http://127.0.0.1:18524/\(name).html"]
            app.launch()
            let status = app.staticTexts["pureline.lab.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 30))
            let ready = NSPredicate(format: "label CONTAINS %@", "Page loaded")
            let wait = XCTNSPredicateExpectation(predicate: ready, object: status)
            XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 150), .completed, "WebKit failed to load \(name): \(status.label)")
            let refresh = app.buttons["Check loaded images"]
            if refresh.exists { refresh.tap() }
            let decoded = NSPredicate(format: "label CONTAINS %@", "\(count)/\(count) images decoded")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: decoded, object: status)], timeout: 45), .completed, "Missing decoded images on \(name): \(status.label)")
            screenshot("WebKit-\(name)-top")
            app.webViews.firstMatch.swipeUp()
            if refresh.exists { refresh.tap() }
            screenshot("WebKit-\(name)-scrolled")
            app.terminate()
        }
    }

    @MainActor
    func test03ActualNativeImagesUseSameEncryptedRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["-purelineLab", "YES", "-purelineNativeLab", "YES"]
        app.launch()
        let status = app.staticTexts["pureline.lab.native.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let loaded = NSPredicate(format: "label == %@", "4 images decoded · 0 failures")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: status)], timeout: 150), .completed, status.label)
        screenshot("Native-URLSession-filtered-images")
        app.terminate()
    }
}
