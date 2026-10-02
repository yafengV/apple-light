import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class ConfettiToolTests: XCTestCase {
  @MainActor func testBurstPaintsWindowWithoutTakingFocus() throws {
    let host = NSHostingView(rootView: Color.black.overlay(
      ConfettiOverlay(burst: UUID(), onFinished: {})
    ).frame(width: 600, height: 400))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderOut(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    var colored = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.25 {
          colored += 1
        }
      }
    }
    XCTAssertGreaterThan(colored, 10)
    XCTAssertFalse(window.isKeyWindow)
  }

  @MainActor func testIndependentModelFiresOnlyWithEnabledPreference() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", fixture.path]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer { server.terminate(); server.waitUntilExit() }
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Fixture could not bind a local port") }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration.baseURL = "http://127.0.0.1:\(port)/v1"
    store.modelConfiguration.model = "fixture"
    store.notificationPreferences = .init(timing: .never)
    var appearance = store.appearance
    appearance.reduceMotion = .off
    store.library.appearance = appearance

    store.draft = "confetti-request"
    await store.sendDraft()
    await store.modelTask?.value
    XCTAssertNil(store.confettiBurst)
    XCTAssertEqual(store.library.chatRuns.last?.status, "succeeded")

    store.confettiEnabled = true
    store.draft = "confetti-request"
    await store.sendDraft()
    await store.modelTask?.value
    XCTAssertNotNil(store.confettiBurst)
    let run = try XCTUnwrap(store.library.chatRuns.last)
    XCTAssertEqual(run.status, "succeeded")
    let taskID = try XCTUnwrap(store.library.task(containing: run.id)?.id)
    let history = store.library.chatContext(taskID: taskID)
    XCTAssertTrue(history.contains { $0.role == "tool" && $0.content.contains("Confetti fired") })
    await store.shutdown()
  }
}
