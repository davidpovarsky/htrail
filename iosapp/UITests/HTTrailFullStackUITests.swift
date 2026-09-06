import Foundation
import UIKit
import XCTest

final class HTTrailFullStackUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testUserJourneyAcrossHTTrailAndEmbeddedClassifier() throws {
        let app = XCUIApplication()
        app.launch()

        try selectTab("Capture", in: app)
        attachScreenshot("01-capture", app: app)
        print("HTTRAIL_UI_STEP tab_capture=pass")

        try selectTab("Compose", in: app)
        if app.buttons["Headers"].exists {
            app.buttons["Headers"].tap()
            app.buttons["Body"].tap()
            app.buttons["Params"].tap()
        }
        attachScreenshot("02-compose", app: app)
        print("HTTRAIL_UI_STEP tab_compose=pass")

        try selectTab("Rules", in: app)
        let pinningSwitch = app.switches["Auto-detect Cert Pinning"]
        if pinningSwitch.exists {
            let original = String(describing: pinningSwitch.value)
            pinningSwitch.tap()
            if String(describing: pinningSwitch.value) != original { pinningSwitch.tap() }
        }
        attachScreenshot("03-rules", app: app)
        print("HTTRAIL_UI_STEP tab_rules=pass")

        try selectTab("Realtime", in: app)
        if app.buttons["MQTT"].exists {
            app.buttons["MQTT"].tap()
            attachScreenshot("04-realtime-mqtt", app: app)
            if app.buttons["WebSocket"].exists { app.buttons["WebSocket"].tap() }
        } else {
            attachScreenshot("04-realtime", app: app)
        }
        print("HTTRAIL_UI_STEP tab_realtime=pass")

        try selectTab("Setup", in: app)
        attachScreenshot("05-setup", app: app)
        print("HTTRAIL_UI_STEP tab_setup=pass")

        try selectTab("Image Filter", in: app)
        XCTAssertTrue(app.staticTexts["AI Image Classifier"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Direct VPN filtering"].exists)
        let directToggle = app.switches.firstMatch
        if directToggle.waitForExistence(timeout: 3) {
            let original = String(describing: directToggle.value)
            directToggle.tap()
            attachScreenshot("06-image-filter-direct-toggle", app: app)
            if String(describing: directToggle.value) != original { directToggle.tap() }
            print("HTTRAIL_UI_STEP direct_filter_toggle=pass")
        }
        attachScreenshot("07-image-filter-home", app: app)
        print("HTTRAIL_UI_STEP tab_image_filter=pass")

        try visitClassifierScreen(button: "Voice Assistant", expectedText: "Voice Assistant", screenshot: "08-voice", app: app)
        XCTAssertTrue(app.buttons["Start Listening"].exists)
        print("HTTRAIL_UI_STEP classifier_voice_ui=pass")
        try goBackToClassifierHome(app)

        try visitClassifierScreen(button: "Live Camera Scanner", expectedText: "Camera not available in Simulator", screenshot: "09-camera-simulator", app: app)
        print("HTTRAIL_UI_STEP classifier_camera_simulator_fallback=pass")
        try goBackToClassifierHome(app)

        try visitClassifierScreen(button: "Diagnostics", expectedText: "Diagnostics", screenshot: "10-diagnostics", app: app)
        print("HTTRAIL_UI_STEP classifier_diagnostics_ui=pass")
        try goBackToClassifierHome(app)

        try visitClassifierScreen(button: "Analyze Image", expectedText: "Nudity Detection", screenshot: "11-analyze-image", app: app)
        try selectSeededPhotoAndAnalyze(in: app)
        print("HTTRAIL_UI_STEP classifier_analyze_ui=pass")
        print("HTTRAIL_UI_STEP classifier_full_picker_inference=pass")
    }

    func testLocalServerLoadsModelsAndClassifiesThroughHTTPAPI() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-htInitialTab", "5"]
        app.launch()

        XCTAssertTrue(app.staticTexts["AI Image Classifier"].waitForExistence(timeout: 12), "Initial-tab QA seam did not open the embedded classifier")
        app.buttons["Local Server"].tap()
        XCTAssertTrue(app.staticTexts["Local Server"].waitForExistence(timeout: 10))
        attachScreenshot("20-local-server-starting", app: app)

        let healthURL = URL(string: "http://127.0.0.1:8765/health")!
        var healthResult: HTTPResult?
        var healthAttempts = 0
        for _ in 0..<90 {
            healthAttempts += 1
            healthResult = request(URLRequest(url: healthURL), timeout: 10)
            if healthResult?.statusCode == 200 { break }
            Thread.sleep(forTimeInterval: 2)
        }

        guard let health = healthResult else {
            XCTFail("Local server never became reachable")
            return
        }
        print("HTTRAIL_SERVER_HEALTH status=\(health.statusCode) attempts=\(healthAttempts) latencyMs=\(health.latencyMs) body=\(health.bodyBase64)")
        XCTAssertEqual(health.statusCode, 200, "Local server did not report both models ready. Body: \(health.bodyString)")
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 10))
        attachScreenshot("21-local-server-ready", app: app)

        UIPasteboard.general.string = nil
        let copyToken = app.buttons["Copy Token"]
        XCTAssertTrue(copyToken.waitForExistence(timeout: 5))
        copyToken.tap()
        Thread.sleep(forTimeInterval: 0.5)
        guard let token = UIPasteboard.general.string, !token.isEmpty else {
            XCTFail("Could not retrieve the local-server bearer token through the real Copy Token UI")
            return
        }

        guard let fixtureURL = Bundle(for: Self.self).url(
            forResource: "ClassificationImageSelected",
            withExtension: "png"
        ) else {
            XCTFail("Classification fixture missing from UI-test bundle")
            return
        }
        let fixture = try Data(contentsOf: fixtureURL)
        var classify = URLRequest(url: URL(string: "http://127.0.0.1:8765/v1/image-safety-classify")!)
        classify.httpMethod = "POST"
        classify.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        classify.setValue("image/png", forHTTPHeaderField: "Content-Type")
        classify.httpBody = fixture

        guard let classification = request(classify, timeout: 180) else {
            XCTFail("The HTTP classification request did not complete")
            return
        }
        print("HTTRAIL_SERVER_CLASSIFY status=\(classification.statusCode) latencyMs=\(classification.latencyMs) fixtureBytes=\(fixture.count) body=\(classification.bodyBase64)")
        XCTAssertEqual(classification.statusCode, 200, "Image classification through the local server failed: \(classification.bodyString)")
        attachScreenshot("22-local-server-after-classification", app: app)
        print("HTTRAIL_UI_STEP local_server_and_http_classification=pass")
    }

    func testApplicationLaunchPerformance() {
        let app = XCUIApplication()
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
        }
        print("HTTRAIL_UI_STEP launch_performance_measurement=pass")
    }

    private func selectSeededPhotoAndAnalyze(in app: XCUIApplication) throws {
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Photo Library Permission") { alert in
            for title in ["Allow Full Access", "Allow Access to All Photos", "Allow", "OK"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        let selectImage = app.buttons["Select Image"]
        let analyzeImage = app.buttons["Analyze Image"]
        XCTAssertTrue(selectImage.waitForExistence(timeout: 5))
        XCTAssertTrue(analyzeImage.exists)
        XCTAssertFalse(analyzeImage.isEnabled, "Analyze should be disabled before a photo is selected")

        selectImage.tap()
        app.tap()

        var photoCell = app.collectionViews.cells.firstMatch
        if !photoCell.waitForExistence(timeout: 12) {
            _ = permissionMonitor
            app.tap()
            photoCell = app.collectionViews.cells.firstMatch
        }
        XCTAssertTrue(photoCell.waitForExistence(timeout: 12), "The seeded photo did not appear in UIImagePickerController")
        photoCell.tap()

        XCTAssertTrue(analyzeImage.waitForExistence(timeout: 12), "Image picker did not dismiss after photo selection")
        XCTAssertTrue(analyzeImage.isEnabled, "Analyze should be enabled after selecting the seeded photo")
        attachScreenshot("12-selected-image", app: app)

        analyzeImage.tap()
        let allowed = app.staticTexts["Allowed"]
        let blocked = app.staticTexts["Blocked"]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline && !allowed.exists && !blocked.exists {
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(allowed.exists || blocked.exists, "UI inference did not produce Allowed or Blocked within 240 seconds")
        attachScreenshot("13-analyzed-image-result", app: app)
    }

    private func selectTab(_ label: String, in app: XCUIApplication) throws {
        if waitForScreen(label, in: app, timeout: 0.5) { return }

        let direct = app.buttons[label].firstMatch
        if direct.waitForExistence(timeout: 3) {
            tapTabButton(direct, label: label)
            if waitForScreen(label, in: app, timeout: 4) { return }
        }

        // iPadOS 26 paginates SwiftUI's top tab bar. With six tabs the final
        // Image Filter tab is reached by the real system "Next Page" affordance,
        // not by a legacy "More" tab.
        let nextPage = app.buttons["Next Page"].firstMatch
        if nextPage.waitForExistence(timeout: 3) {
            nextPage.tap()
            if waitForScreen(label, in: app, timeout: 2) { return }
            let paged = app.buttons[label].firstMatch
            if paged.waitForExistence(timeout: 4) {
                paged.tap()
                if waitForScreen(label, in: app, timeout: 6) { return }
            }
        }

        XCTFail("Tab \(label) is not reachable through the iPad tab bar")
    }

    private func tapTabButton(_ button: XCUIElement, label: String) {
        if label == "Setup" {
            // On iPadOS 26 the system's narrow Next Page affordance overlaps the
            // leading portion of the Setup tab's accessibility frame. Tap the
            // unobscured trailing side, exactly as a user can.
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        } else {
            button.tap()
        }
    }

    private func waitForScreen(_ label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        switch label {
        case "Capture":
            return app.buttons["Start (This iPad)"].waitForExistence(timeout: timeout)
        case "Compose":
            return app.staticTexts["Compose"].waitForExistence(timeout: timeout)
        case "Rules":
            return app.staticTexts["INTERCEPTION RULES"].waitForExistence(timeout: timeout)
        case "Realtime":
            return app.buttons["Connect"].waitForExistence(timeout: timeout)
        case "Setup":
            return app.staticTexts["Certificate Authority"].waitForExistence(timeout: timeout)
                || app.staticTexts["CERTIFICATE AUTHORITY"].waitForExistence(timeout: 0.2)
        case "Image Filter":
            return app.staticTexts["AI Image Classifier"].waitForExistence(timeout: timeout)
        default:
            return app.staticTexts[label].waitForExistence(timeout: timeout)
        }
    }

    private func visitClassifierScreen(
        button: String,
        expectedText: String,
        screenshot: String,
        app: XCUIApplication
    ) throws {
        let element = app.buttons[button]
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing classifier button: \(button)")
        element.tap()
        XCTAssertTrue(app.staticTexts[expectedText].waitForExistence(timeout: 10), "Missing screen content: \(expectedText)")
        attachScreenshot(screenshot, app: app)
    }

    private func goBackToClassifierHome(_ app: XCUIApplication) throws {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Classifier screen has no navigation back button")
        back.tap()
        XCTAssertTrue(app.staticTexts["AI Image Classifier"].waitForExistence(timeout: 8))
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct HTTPResult {
        let statusCode: Int
        let data: Data
        let latencyMs: Int
        var bodyString: String { String(data: data, encoding: .utf8) ?? "<non-UTF8>" }
        var bodyBase64: String { data.base64EncodedString() }
    }

    private final class HTTPResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: HTTPResult?

        func store(_ result: HTTPResult) {
            lock.lock()
            storage = result
            lock.unlock()
        }

        func load() -> HTTPResult? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func request(_ request: URLRequest, timeout: TimeInterval) -> HTTPResult? {
        let semaphore = DispatchSemaphore(value: 0)
        let start = Date()
        let box = HTTPResultBox()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            box.store(HTTPResult(
                statusCode: http.statusCode,
                data: data ?? Data(),
                latencyMs: Int(Date().timeIntervalSince(start) * 1_000)
            ))
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
            task.cancel()
            return nil
        }
        session.invalidateAndCancel()
        return box.load()
    }
}
