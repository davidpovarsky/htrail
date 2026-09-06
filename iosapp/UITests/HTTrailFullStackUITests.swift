import Foundation
import UIKit
import XCTest

final class HTTrailFullStackUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testUserJourneyAcrossHTTrailAndEmbeddedClassifier() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-htDemo", "1"]
        app.launch()

        try selectTab("Capture", in: app)
        attachScreenshot("01-capture", app: app)
        print("HTTRAIL_UI_STEP tab_capture=pass")

        try selectTab("Compose", in: app)
        XCTAssertTrue(app.staticTexts["Compose"].waitForExistence(timeout: 8))
        if app.buttons["Headers"].exists {
            app.buttons["Headers"].tap()
            app.buttons["Body"].tap()
            app.buttons["Params"].tap()
        }
        attachScreenshot("02-compose", app: app)
        print("HTTRAIL_UI_STEP tab_compose=pass")

        try selectTab("Rules", in: app)
        XCTAssertTrue(app.staticTexts["Rules"].waitForExistence(timeout: 8))
        let pinningSwitch = app.switches["Auto-detect Cert Pinning"]
        if pinningSwitch.exists {
            let original = String(describing: pinningSwitch.value)
            pinningSwitch.tap()
            if String(describing: pinningSwitch.value) != original { pinningSwitch.tap() }
        }
        attachScreenshot("03-rules", app: app)
        print("HTTRAIL_UI_STEP tab_rules=pass")

        try selectTab("Realtime", in: app)
        XCTAssertTrue(app.staticTexts["Realtime"].waitForExistence(timeout: 8))
        if app.buttons["MQTT"].exists {
            app.buttons["MQTT"].tap()
            attachScreenshot("04-realtime-mqtt", app: app)
            if app.buttons["WebSocket"].exists { app.buttons["WebSocket"].tap() }
        } else {
            attachScreenshot("04-realtime", app: app)
        }
        print("HTTRAIL_UI_STEP tab_realtime=pass")

        try selectTab("Setup", in: app)
        XCTAssertTrue(app.staticTexts["Setup"].waitForExistence(timeout: 8))
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
        XCTAssertTrue(app.buttons["Select Image"].exists)
        XCTAssertTrue(app.buttons["Analyze Image"].exists)
        print("HTTRAIL_UI_STEP classifier_analyze_ui=pass")
    }

    func testLocalServerLoadsModelsAndClassifiesThroughHTTPAPI() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-htInitialTab", "5"]
        app.launch()

        XCTAssertTrue(app.staticTexts["AI Image Classifier"].waitForExistence(timeout: 12))
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
        app.launchArguments = ["-htDemo", "1"]
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
        }
        print("HTTRAIL_UI_STEP launch_performance_measurement=pass")
    }

    private func selectTab(_ label: String, in app: XCUIApplication) throws {
        let direct = app.tabBars.buttons[label]
        if direct.waitForExistence(timeout: 3) {
            direct.tap()
            XCTAssertTrue(direct.isSelected || app.staticTexts[label].waitForExistence(timeout: 5))
            return
        }

        let more = app.tabBars.buttons["More"]
        if more.waitForExistence(timeout: 3) {
            more.tap()
            let item = app.staticTexts[label].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Could not find \(label) in the system More tab")
            item.tap()
            return
        }
        XCTFail("Tab \(label) is not reachable")
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

    private func request(_ request: URLRequest, timeout: TimeInterval) -> HTTPResult? {
        let semaphore = DispatchSemaphore(value: 0)
        let start = Date()
        var result: HTTPResult?
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            result = HTTPResult(
                statusCode: http.statusCode,
                data: data ?? Data(),
                latencyMs: Int(Date().timeIntervalSince(start) * 1_000)
            )
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
            task.cancel()
            return nil
        }
        session.invalidateAndCancel()
        return result
    }
}
