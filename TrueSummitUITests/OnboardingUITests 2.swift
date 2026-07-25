import XCTest

/// First-run wizard: the hands-on setup flow's skip and complete paths, and
/// that the choice sticks across a relaunch.
///
/// `--uitest-reset-onboarding` (handled in RootView.onAppear) clears the
/// onboarding flags and bypasses the existing-user skip, so the wizard
/// appears deterministically no matter what data the simulator holds.
final class OnboardingUITests: XCTestCase {

    /// The very first launch on a cold simulator can take 30s+ (install,
    /// debugserver attach, store seeding) before the UI settles.
    private let launchTimeout: TimeInterval = 60

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchWithFreshOnboarding() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset-onboarding"]
        app.launch()
        // The simulator can drop launch arguments on the first launch after
        // Xcode (re)installs the app, so the reset never runs and stale
        // onboarding state hides the wizard. Relaunching recovers: only
        // that first launch is affected.
        if !app.buttons["onboardingSkipButton"].waitForExistence(timeout: 15) {
            app.terminate()
            app.launch()
        }
        return app
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hittable = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: hittable, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Tapping a neutral, non-interactive title resigns the keyboard so the
    /// footer's primary button is hittable again after text entry.
    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication, title: String) {
        let heading = app.staticTexts[title]
        if heading.exists { heading.tap() }
    }

    @MainActor
    func testSkipSeedsSamplesAndStaysDismissed() throws {
        let app = launchWithFreshOnboarding()

        let skip = app.buttons["onboardingSkipButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: launchTimeout), "Wizard should appear on a fresh install")
        skip.tap()

        // The wizard is gone and the Budget tab's checklist is showing.
        let checklist = app.descendants(matching: .any)["gettingStartedHeader"]
        XCTAssertTrue(checklist.waitForExistence(timeout: 10), "Getting Started checklist should show after skipping")
        XCTAssertFalse(app.buttons["onboardingContinueButton"].exists)

        // Relaunch without the reset flag: the wizard must not come back.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(checklist.waitForExistence(timeout: launchTimeout), "Checklist should persist across relaunch")
        XCTAssertFalse(app.buttons["onboardingSkipButton"].exists, "Wizard should not reappear once skipped")
    }

    @MainActor
    func testCompletingWizardLandsOnBudgetWithChecklist() throws {
        let app = launchWithFreshOnboarding()

        let continueButton = app.buttons["onboardingContinueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: launchTimeout), "Wizard should appear on a fresh install")

        // Step 0: welcome → accounts.
        continueButton.tap()

        // Step 1: name an account, then advance.
        let accountName = app.textFields["onboardingAccountName"]
        XCTAssertTrue(accountName.waitForExistence(timeout: 10), "Accounts step should follow welcome")
        accountName.tap()
        accountName.typeText("Checking")
        let balance = app.textFields["onboardingAccountBalance"]
        balance.tap()
        balance.typeText("2000")
        dismissKeyboard(app, title: "Add Your Accounts")
        XCTAssertTrue(waitForHittable(continueButton, timeout: 10))
        continueButton.tap()

        // Step 2: the Ready to Assign reveal.
        XCTAssertTrue(app.descendants(matching: .any)["onboardingReadyToAssignAmount"].waitForExistence(timeout: 10),
                      "Ready to Assign step should follow accounts")
        continueButton.tap()

        // Step 3: categories (starter set selected by default → can advance).
        XCTAssertTrue(app.textFields["onboardingNewCategoryField"].waitForExistence(timeout: 10),
                      "Categories step should follow Ready to Assign")
        continueButton.tap()

        // Step 4: assign step, primary button becomes "Review Budget".
        XCTAssertTrue(app.descendants(matching: .any)["onboardingLeftToAssign"].waitForExistence(timeout: 10),
                      "Assign step should follow categories")
        XCTAssertTrue(waitForHittable(continueButton, timeout: 10))
        continueButton.tap()

        // Step 5: done step offers the bank shortcut; the primary finishes.
        XCTAssertTrue(app.buttons["onboardingConnectBankButton"].waitForExistence(timeout: 10),
                      "Connect a Bank should be offered on the last step")
        continueButton.tap() // "Start Budgeting"

        let checklist = app.descendants(matching: .any)["gettingStartedHeader"]
        XCTAssertTrue(checklist.waitForExistence(timeout: 10), "Getting Started checklist should show after finishing")
        XCTAssertFalse(continueButton.exists)
    }

    @MainActor
    func testGuidedTourVisitsEveryStopAndCompletes() throws {
        let app = launchWithFreshOnboarding()

        let skip = app.buttons["onboardingSkipButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: launchTimeout), "Wizard should appear on a fresh install")
        skip.tap()

        let checklist = app.descendants(matching: .any)["gettingStartedHeader"]
        XCTAssertTrue(checklist.waitForExistence(timeout: 10), "Getting Started checklist should show after skipping")

        // The hero above the checklist is taller than one screen and List
        // rows are created lazily, so the tour row doesn't even *exist*
        // until scrolled near — scroll first, then assert.
        let tourRow = app.buttons["gettingStartedTour"]
        var scrollAttempts = 0
        while !(tourRow.exists && tourRow.isHittable) && scrollAttempts < 8 {
            app.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(tourRow.isHittable, "Take-the-tour step should be reachable by scrolling")
        tourRow.tap()

        // One button walks the whole tour: "Next" for six stops, "Done" on
        // the seventh. Each advance switches tabs, so let that settle.
        let advance = app.buttons["featureTourNextButton"]
        XCTAssertTrue(advance.waitForExistence(timeout: 10), "Tour card should appear")
        for _ in 0..<7 {
            XCTAssertTrue(waitForHittable(advance, timeout: 10), "Tour card should stay up between stops")
            Thread.sleep(forTimeInterval: 0.4)
            advance.tap()
        }

        let gone = NSPredicate(format: "exists == false")
        let dismissed = XCTNSPredicateExpectation(predicate: gone, object: advance)
        XCTAssertEqual(XCTWaiter().wait(for: [dismissed], timeout: 5), .completed,
                       "Tour card should dismiss after Done")
    }
}
