import XCTest

/// The App Store screenshots, saved as attachments of the test result. `atk screenshots capture`
/// runs it on the iPhone 17 Pro Max and iPad Pro 13-inch simulators and on this Mac, and exports
/// them. Controls are found by label or identifier whatever their kind: a button on iOS is a radio
/// button, tab, pop-up or menu button on the Mac.
final class ScreenshotTests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        // Greenwich, so the pictures show no one's home. The simulators are put in dark mode; the
        // Mac app is told to be dark, and its window sized to the Mac App Store's 2880 × 1800.
        #if os(macOS)
        let settings = #"{"latitude":51.4779,"longitude":-0.0015,"hasLocation":true,"alwaysDark":true}"#
        app.launchArguments += ["-screenshotWindow", "YES"]
        #else
        let settings = #"{"latitude":51.4779,"longitude":-0.0015,"hasLocation":true}"#
        #endif
        app.launchArguments += ["-settings", "<" + settings.utf8.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
        #if os(iOS)
        // Landscape on the iPad, where the list and the sky sit side by side.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        #endif
        #if os(iOS)
        // The simulators' permission alerts. On the Mac the location is given, and XCTest's
        // check for interruptions before each click timed out (3 Nov 2026).
        addUIInterruptionMonitor(withDescription: "Permission") { alert in
            alert.buttons.element(boundBy: 1).tap()
            return true
        }
        #endif
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
        // A static text on iOS; a button in an outline row on the Mac.
        let row = element(page)
        if !row.waitForExistence(timeout: 3) {
            press(app.navigationBars.buttons.firstMatch)
            _ = row.waitForExistence(timeout: 5)
        }
        press(row)
        sleep(3)
    }

    /// Every satellite in a source, from the Objects tab's list of sources.
    private func selectAll(in source: String) {
        open(source)
        let menu = element("Select satellites in \(source)")
        guard menu.waitForExistence(timeout: 20) else { return }
        press(menu)
        press(anyKind.matching(NSPredicate(format: "label BEGINSWITH 'Select all' OR title BEGINSWITH 'Select all'")).firstMatch)
        sleep(5)
    }

    /// Opens the menu whose title contains `text` and picks its last, widest, choice.
    private func choose(containing text: String) {
        #if os(macOS)
        // A pop-up button, showing its choice as its value; the choices are menu items.
        let menu = app.popUpButtons.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
        guard menu.waitForExistence(timeout: 5) else { return }
        press(menu)
        sleep(1)
        let choices = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", text)).allElementsBoundByIndex
        #else
        let menu = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        guard menu.waitForExistence(timeout: 5) else { return }
        press(menu)
        sleep(1)
        let choices = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
        #endif
        if let choice = choices.last(where: { $0.isHittable }) { press(choice) }
        sleep(2)
    }

    /// Of the first few passes, the one that climbs highest.
    private func tapHighestPass() {
        #if os(macOS)
        let rows = app.outlines.firstMatch.outlineRows
        #else
        let rows = app.collectionViews.cells
        #endif
        guard rows.element(boundBy: 0).waitForExistence(timeout: 20) else { return }
        let peaks = (0..<min(6, rows.count)).map { index -> (Int, Int) in
            // On the Mac the row's text is the label of the button inside it.
            let texts = rows.element(boundBy: index).descendants(matching: .any).allElementsBoundByIndex.map(\.label)
            // The highest "NN°" in the row: "max 78°" while it's up, "73°" over "peak" before.
            let peak = texts.flatMap { label in
                label.matches(of: /(\d+)°/).compactMap { Int($0.output.1) }
            }.max() ?? 0
            return (index, peak)
        }
        let best = peaks.max { $0.1 < $1.1 }?.0 ?? 0
        press(rows.element(boundBy: best))
        sleep(3)
    }

    private func tab(_ index: Int) {
        // By the tab's symbol: the iPad's tabs are at the top, outside any tab bar.
        let symbols = ["scope", "binoculars", "checklist", "moon.stars", "gearshape"]
        #if os(macOS)
        // The Mac's tabs, in the toolbar, carry the same identifiers.
        let button = app.tabs.matching(identifier: symbols[index]).firstMatch
        #else
        let button = app.tabBars.firstMatch.exists ? app.tabBars.buttons.element(boundBy: index)
            : app.buttons.matching(identifier: symbols[index]).firstMatch
        #endif
        if button.waitForExistence(timeout: 10) { press(button) }
        sleep(3)
    }

    private func segment(_ label: String) {
        let button = element(label)
        if button.waitForExistence(timeout: 5) { press(button) }
        sleep(3)
    }

    private var anyKind: XCUIElementQuery { app.descendants(matching: .any) }

    /// A tap, or on the Mac a click at the control's centre: a plain click on a toolbar tab
    /// doesn't switch tabs there. A control that isn't there is skipped, not a failure.
    private func press(_ element: XCUIElement) {
        guard element.exists else { return }
        #if os(macOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        element.tap()
        #endif
    }

    /// The first control with this label, whatever its kind.
    private func element(_ label: String) -> XCUIElement {
        anyKind.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func snap(_ name: String) {
        // An iPhone Duo has two screens, and the main one is the outside screen, dark while it's
        // unfolded. The app's window is on whichever screen is in use.
        // On the Mac, the window alone, without the desktop around it.
        #if os(macOS)
        let picture = app.windows.firstMatch.screenshot()
        #else
        let picture = XCUIScreen.screens.count > 1 ? app.windows.firstMatch.screenshot() : XCUIScreen.main.screenshot()
        #endif
        let shot = XCTAttachment(screenshot: picture)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
