import XCTest

final class AppUITests: XCTestCase {
    func testWorkspaceTrialSettingsAndPauseFlow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo", "--workspace"]
        app.launch()
        let window = app.windows["BiQuad Monitor — Signal Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(window.buttons["Antenna Lab"].waitForExistence(timeout: 5))
        window.buttons["Antenna Lab"].click()
        XCTAssertTrue(window.buttons["Start trial"].isEnabled)
        window.buttons["Start trial"].click()
        let stop = window.buttons["Stop trial · keep partial data"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.click()
        XCTAssertTrue(window.buttons["Set reference"].waitForExistence(timeout: 5))
        window.buttons["Sessions"].click()
        XCTAssertTrue(window.buttons["Inspect"].firstMatch.waitForExistence(timeout: 5))
        window.buttons["Inspect"].firstMatch.click()
        XCTAssertTrue(window.staticTexts["Saved trials · select here, then open Antenna Lab"].waitForExistence(timeout: 5))
        window.buttons["Settings"].click()
        let settings = app.windows["BiQuad Monitor — Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(settings.frame.minY, 0)
        XCTAssertTrue(settings.secureTextFields.firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "workspace-session-flow"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
}
