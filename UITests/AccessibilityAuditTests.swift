import XCTest

/// Runs Apple's accessibility audit on each tab and lists what it finds, without failing on it:
/// the list is the report. Elements VoiceOver can't name are listed too.
final class AccessibilityAuditTests: XCTestCase {
    func testEveryTab() {
        let app = XCUIApplication()
        // Greenwich, so there are passes to show without asking for a location.
        let settings = #"{"latitude":51.4779,"longitude":-0.0015,"hasLocation":true}"#
        app.launchArguments += ["-settings", "<" + settings.utf8.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "Permission") { alert in
            alert.buttons.element(boundBy: 1).tap()
            return true
        }

        var report: [String] = []
        for tab in ["Observe", "Look up", "Objects", "Conjunctions", "Settings"] {
            let button = app.tabBars.buttons[tab]
            guard button.waitForExistence(timeout: 10) else {
                report.append("\(tab): tab not found")
                continue
            }
            button.tap()
            sleep(4)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = tab
            shot.lifetime = .keepAlways
            add(shot)
            do {
                try app.performAccessibilityAudit { issue in
                    let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' '\($0.identifier)'" } ?? "-"
                    report.append("\(tab) | \(issue.auditType) | \(issue.compactDescription) | \(element)")
                    return true
                }
            } catch {
                report.append("\(tab) | audit failed: \(error.localizedDescription)")
            }
            // Not switches: a Toggle's switch reports no label of its own, but VoiceOver reads its row's.
            for type in [XCUIElement.ElementType.button, .image, .slider] {
                for element in app.descendants(matching: type).allElementsBoundByIndex
                where element.exists && element.isHittable && element.label.isEmpty {
                    report.append("\(tab) | unlabelled | \(type.rawValue) \(element.identifier) at \(element.frame)")
                }
            }
        }
        let text = report.joined(separator: "\n")
        print("AUDIT-BEGIN\n\(text)\nAUDIT-END")
        let attachment = XCTAttachment(string: text)
        attachment.name = "Accessibility audit"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
