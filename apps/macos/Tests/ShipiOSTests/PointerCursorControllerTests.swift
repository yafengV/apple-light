import AppKit
import SwiftTerm
import WebKit
import XCTest

@testable import ShipiOS

@MainActor
final class PointerCursorControllerTests: XCTestCase {
  func testClickableControlsUsePointerAndDisabledControlsDoNot() {
    let button = NSButton(title: "Open", target: nil, action: nil)
    XCTAssertTrue(PointerCursorController.cursorOverride(for: button) === NSCursor.pointingHand)

    button.isEnabled = false
    XCTAssertTrue(PointerCursorController.cursorOverride(for: button) === NSCursor.arrow)
    let buttonChild = NSView()
    buttonChild.setAccessibilityRole(.link)
    button.addSubview(buttonChild)
    XCTAssertTrue(PointerCursorController.cursorOverride(for: buttonChild) === NSCursor.arrow)

    let container = NSView()
    let nested = NSView()
    container.setAccessibilityRole(.link)
    container.addSubview(nested)
    XCTAssertTrue(PointerCursorController.cursorOverride(for: nested) === NSCursor.pointingHand)
    XCTAssertTrue(PointerCursorController.cursorOverride(for: NSView()) === NSCursor.arrow)
  }

  func testNativeTextResizeAndImageCursorsRemainOwnedByTheirViews() {
    let textField = NSTextField()
    let fieldChild = NSView()
    textField.addSubview(fieldChild)
    XCTAssertNil(PointerCursorController.cursorOverride(for: fieldChild))
    XCTAssertNil(PointerCursorController.cursorOverride(for: NSTextView()))
    XCTAssertNil(PointerCursorController.cursorOverride(for: PanelResizeHandle.ResizeView()))
    XCTAssertNil(PointerCursorController.cursorOverride(for: ImagePreviewCanvas.Picture()))

    let webView = WKWebView(frame: .zero)
    let webButton = NSButton(title: "Link", target: nil, action: nil)
    webView.addSubview(webButton)
    XCTAssertNil(PointerCursorController.cursorOverride(for: webButton))
    XCTAssertNil(PointerCursorController.cursorOverride(for: TerminalView(frame: .zero, font: nil)))
  }
}
