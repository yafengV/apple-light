import XCTest

/// A fixed acceptance contract for the model-authored app. Do not modify this
/// test to accommodate a generated implementation that fails the requirement.
final class HelloShipiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        if let app, testRun?.hasSucceeded == false {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Counter acceptance failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        app?.terminate()
        app = nil
    }

    func testCounterStartsAtZeroIncrementsTwiceAndResets() {
        let value = app.staticTexts["counter.value"]
        let increment = app.buttons["counter.increment"]
        let reset = app.buttons["counter.reset"]
        XCTAssertTrue(value.waitForExistence(timeout: 5), "The counter must expose counter.value")
        XCTAssertEqual(value.label, "0", "The counter must start at zero")
        XCTAssertTrue(increment.exists && increment.isHittable, "The increment action must be usable")
        XCTAssertTrue(reset.exists && reset.isHittable, "The reset action must be usable")
        increment.tap()
        XCTAssertEqual(value.label, "1", "The first tap must increment by exactly one")
        increment.tap()
        XCTAssertEqual(value.label, "2", "Two taps must produce two")
        reset.tap()
        XCTAssertEqual(value.label, "0", "Reset must return to zero")
    }
}
