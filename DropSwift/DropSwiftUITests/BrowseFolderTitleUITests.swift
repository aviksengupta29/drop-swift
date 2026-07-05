//
//  BrowseFolderTitleUITests.swift
//  DropSwiftUITests
//
//  End-to-end verification that the Browse tab shows the server's shared
//  folder NAME as its title, and auto-updates when the Mac switches folders.
//
//  Requires a local DropSwift server reachable at 127.0.0.1:8080 with access
//  code 123456 (the verify harness starts one sharing "FolderAlpha", then
//  restarts it sharing "FolderBravo" mid-test).
//

import XCTest

final class BrowseFolderTitleUITests: XCTestCase {

    @MainActor
    func testFolderTitleShownAndAutoRefresh() throws {
        let app = XCUIApplication()
        app.launch()

        // --- Connect manually to the local server -------------------------
        let manual = app.buttons["Enter address manually"]
        XCTAssertTrue(manual.waitForExistence(timeout: 15), "manual entry toggle missing")
        manual.tap()

        let host = app.textFields["192.168.1.5"]
        XCTAssertTrue(host.waitForExistence(timeout: 5), "host field missing")
        host.tap()
        host.typeText("127.0.0.1")

        app.buttons["manual-connect"].tap()

        // --- Access-code sheet -------------------------------------------
        let code = app.textFields["000000"]
        XCTAssertTrue(code.waitForExistence(timeout: 15), "code field missing")
        code.tap()
        code.typeText("123456")
        app.buttons["code-connect"].tap()

        // --- Go to Browse -------------------------------------------------
        let browseTab = app.buttons["tab-Browse"]
        XCTAssertTrue(browseTab.waitForExistence(timeout: 20), "Browse tab missing (did we connect?)")
        browseTab.tap()

        // --- Assert the title is the shared folder name -------------------
        let alpha = app.navigationBars["FolderAlpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 20),
                      "Browse title did not show the shared folder name 'FolderAlpha'")
        attachScreenshot(app, name: "01-browse-FolderAlpha")

        // --- The Mac switches folders → title must auto-refresh -----------
        // (harness restarts the server sharing FolderBravo about now)
        let bravo = app.navigationBars["FolderBravo"]
        var appeared = false
        for _ in 0..<60 {
            if bravo.exists { appeared = true; break }
            // dismiss a transient "Disconnected" alert if the restart tripped it
            let ok = app.alerts.buttons["OK"]
            if ok.exists { ok.tap() }
            sleep(1)
        }
        XCTAssertTrue(appeared,
                      "Browse title did not auto-update to 'FolderBravo' after the server switched folders")
        attachScreenshot(app, name: "02-browse-FolderBravo")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
