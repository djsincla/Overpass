import XCTest

/// The App Store screenshots, saved as attachments of the test result. Run on the iPhone 17 Pro Max
/// and iPad Pro 13-inch simulators with `scripts/screenshots.sh`, which also exports them.
final class ScreenshotTests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        // Greenwich, so the pictures show no one's home.
        let settings = #"{"latitude":51.4779,"longitude":-0.0015,"hasLocation":true}"#
        app.launchArguments += ["-settings", "<" + settings.utf8.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
        // Landscape on the iPad, where the list and the sky sit side by side.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        addUIInterruptionMonitor(withDescription: "Permission") { alert in
            alert.buttons.element(boundBy: 1).tap()
            return true
        }
    }

    func testScreenshots() {
        tab(2)
        selectAll(in: "Space stations")
        selectAll(in: "Brightest (visual)")
        open("Catalogues")
        snap("5 Objects")
        tab(0)
        segment("Passes")
        segment("Sky")
        tapHighestPass()
        snap("1 Sky")
        segment("Globe")
        snap("2 Globe")
        segment("Map")
        snap("3 Map")
        segment("Status")
        snap("4 Status")
        tab(3)
        choose(containing: "within")
        choose(containing: "days")
        sleep(10)
        snap("6 Conjunctions")
    }

    /// A page from the Objects tab's sidebar or list.
    private func open(_ page: String) {
        let row = app.staticTexts[page].firstMatch
        if !row.waitForExistence(timeout: 3) {
            app.navigationBars.buttons.firstMatch.tap()
            _ = row.waitForExistence(timeout: 5)
        }
        row.tap()
        sleep(3)
    }

    /// Every satellite in a source, from the Objects tab's list of sources.
    private func selectAll(in source: String) {
        open(source)
        let menu = app.buttons["Select satellites in \(source)"].firstMatch
        guard menu.waitForExistence(timeout: 20) else { return }
        menu.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select all'")).firstMatch.tap()
        sleep(5)
    }

    /// Opens the menu whose title contains `text` and picks its last, widest, choice.
    private func choose(containing text: String) {
        let menu = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        guard menu.waitForExistence(timeout: 5) else { return }
        menu.tap()
        sleep(1)
        let choices = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
        choices.last { $0.isHittable }?.tap()
        sleep(2)
    }

    /// Of the first few passes, the one that climbs highest.
    private func tapHighestPass() {
        let rows = app.collectionViews.cells
        guard rows.element(boundBy: 0).waitForExistence(timeout: 20) else { return }
        let peaks = (0..<min(6, rows.count)).map { index -> (Int, Int) in
            let texts = rows.element(boundBy: index).staticTexts.allElementsBoundByIndex.map(\.label)
            let peak = texts.compactMap { label -> Int? in
                guard let range = label.range(of: #"max (\d+)°"#, options: .regularExpression) else { return nil }
                return Int(label[range].dropFirst(4).dropLast())
            }.first ?? 0
            return (index, peak)
        }
        let best = peaks.max { $0.1 < $1.1 }?.0 ?? 0
        rows.element(boundBy: best).tap()
        sleep(3)
    }

    private func tab(_ index: Int) {
        // By the tab's symbol: the iPad's tabs are at the top, outside any tab bar.
        let symbols = ["scope", "binoculars", "checklist", "moon.stars", "gearshape"]
        let button = app.tabBars.firstMatch.exists ? app.tabBars.buttons.element(boundBy: index)
            : app.buttons.matching(identifier: symbols[index]).firstMatch
        if button.waitForExistence(timeout: 10) { button.tap() }
        sleep(3)
    }

    private func segment(_ label: String) {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 5) { button.tap() }
        sleep(3)
    }

    private func snap(_ name: String) {
        // An iPhone Duo has two screens, and the main one is the outside screen, dark while it's
        // unfolded. The app's window is on whichever screen is in use.
        let picture = XCUIScreen.screens.count > 1 ? app.windows.firstMatch.screenshot() : XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: picture)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
