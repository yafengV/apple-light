// Run only inside the explicitly enabled interactive XCTest host.
// Scheduling from an AppKit timer keeps asynchronous MainActor tests runnable.
import AppKit
import XCTest
final class WindowFailureObserver: NSObject, XCTestObservation {
 var reported = Set<String>()
 func testCase(_ testCase: XCTestCase, didFailWithDescription description: String,
               inFile filePath: String?, atLine lineNumber: Int) {
  guard reported.insert(testCase.name).inserted else { return }
  func fields(_ view:NSView) -> [[String:Any]] {
   if let field=view as? NSSearchField {
    return [["valueLength":field.stringValue.utf16.count,
     "editorLength":field.currentEditor()?.string.utf16.count ?? -1,
     "enabled":field.isEnabled, "editing":field.currentEditor() != nil]]
   }
   return view.subviews.flatMap(fields)
  }
  let windows = NSApp.windows.map { window -> [String:Any] in
   ["number":window.windowNumber, "title":window.title,
    "key":window.isKeyWindow, "main":window.isMainWindow,
    "visible":window.isVisible, "level":window.level.rawValue,
    "responder":window.firstResponder.map { String(describing:type(of:$0)) } ?? "nil",
    "searchFields":window.contentView.map(fields) ?? []]
  }
  let value: [String:Any] = ["stage":"first-assertion-failure", "test":testCase.name,
   "description":description, "line":lineNumber, "active":NSApp.isActive,
   "windows":windows]
  if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {
   print(String(decoding:data,as:UTF8.self)); fflush(stdout)
  }
 }
}
final class Delegate: NSObject, NSApplicationDelegate {
 let resultPath: String
 let bundlePath: String
 var activationDeadline: Date?
 var launcher: NSWindow?
 let available = ["testNativeActualMainMountsSidebarModalInsideExistingWindowAndInlineEditorBlurSaves", "testNativeActualMainPreparationCancelAndRetryActionsStayInExistingWindow", "testNativeRenameMountedBeforeWindowBecomesKeyFocusesOnlyOnce", "testNativeReturningFromFullBrowserMountsFocusedComposer", "testNativeTabThenImmediateSpaceActivatesTheNewSwitch", "testNativeRapidConfirmationKeysUseTheLatestSelection", "testNativeCancelledSettingsExitRestoresSearchAndBackKeyboardFocus", "testNativeSearchTabThenImmediateActivationKeepsNavigationOrder", "testNativeEnvironmentSaveAndDiscardResumeOverviewKeyboardFocus", "testActualScreenContextUsesReleaseActivationAndPersistsWithoutStartingVoice", "testActualVoiceHotkeyCaptureSavesAndEscapeLeavesBindingUnchanged", "testActualAdvancedSpaceReleaseThenTabCaptureSavesAndCollapsePreservesBinding", "testActualBareModifierOverlapEndsCaptureAndPreservesSavedBinding", "testActualClearIsTabReachableAndSpaceReleasePersistsOnlyItsBinding", "testActualVoiceChatAndSingleTapFailuresStayInTheirRowsAndRetryClearsOnlyItsError", "testCollapsingDuringActualCaptureUnmountsItAndReturnsFocusWithoutChangingBinding", "testConflictingCaptureExitsWithoutChangingSavedShortcutOrRegisteringAgain", "testLeavingVoicePageResetsDisclosureAndCancelsCaptureWithoutClearingSavedBinding", "testOldCaptureCallbacksCannotCancelOrWriteIntoNewCaptureOfSameMode", "testRejectedReservedKeyEndsActualCaptureWithoutReplacingExistingBinding", "testRepeatedKeyDoesNotConsumeActualCaptureButNextOrdinaryKeySaves", "testSecondEventBeforeRecorderUnmountCannotOverwriteBindingAfterConflict", "testNativeGitPageSegmentsChangePersistedReviewDeliveryAndSearchRoutesBackToIt", "testNativeBrowserOverviewLinkPreferencePersistsAndManagerNavigatesToHistory"]
 let selected: [String]
 init(bundlePath: String, resultPath: String) {
  self.bundlePath=bundlePath; self.resultPath=resultPath
  let requested = Array(CommandLine.arguments.dropFirst(3))
  selected = requested.isEmpty ? available : requested
 }
 func applicationDidFinishLaunching(_ notification: Notification) {
  let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 680,height: 220),styleMask: [.titled,.closable],backing: .buffered,defer: false)
  window.title = "ShipiOS 原生交互验收"
  let version = NSTextField(wrappingLabelWithString: ProcessInfo.processInfo.environment["SHIPIOS_TEST_BUILD_LABEL"] ?? "构建来源未提供")
  version.frame = NSRect(x: 24,y: 110,width: 632,height: 85)
  version.font = .systemFont(ofSize: 12)
  version.textColor = .secondaryLabelColor
  window.contentView?.addSubview(version)
  let button = NSButton(title: "开始验收",target: self,action: #selector(startTests))
  button.frame = NSRect(x: 240,y: 45,width: 200,height: 40)
  window.contentView?.addSubview(button)
  launcher = window
  window.center(); window.makeKeyAndOrderFront(nil)
  NSApp.activate(ignoringOtherApps: true)
  write(["stage":"ready","active":NSApp.isActive])
 }
 @objc func startTests() {
  write(["stage":"clicked","active":NSApp.isActive,"key":launcher?.isKeyWindow ?? false])
  NSApp.activate(ignoringOtherApps: true)
  launcher?.makeKeyAndOrderFront(nil)
  activationDeadline=Date().addingTimeInterval(5)
  perform(#selector(waitForActivation), with:nil, afterDelay:0.1)
 }
 @objc func waitForActivation() {
  if NSApp.isActive && launcher?.isKeyWindow == true { runTests(); return }
  if Date() > activationDeadline! { write(["stage":"failed", "error":"No actual foreground activation"]); NSApp.terminate(nil); return }
  perform(#selector(waitForActivation), with:nil, afterDelay:0.1)
 }
 @objc func runTests() {
   // Activation has been verified. The launcher must no longer compete with
   // each test's key window when the initiating accessibility click completes.
   launcher?.orderOut(nil)
   guard !selected.isEmpty, Set(selected).count == selected.count,
     selected.allSatisfy(available.contains) else {
    write(["stage":"failed", "error":"Invalid selected methods"]); NSApp.terminate(nil); return
   }
   guard let bundle=Bundle(path:bundlePath) else { write(["error":"Invalid bundle path"]); NSApp.terminate(nil); return }
   do { try bundle.loadAndReturnError() } catch { write(["error":String(describing:error)]); NSApp.terminate(nil); return }
   let all=XCTestSuite.default
   let suite=XCTestSuite(name:"ShipiOS Foreground")
   func collect(_ test: XCTest) {
    if let group=test as? XCTestSuite { group.tests.forEach(collect) }
    else if selected.contains(where:{ test.name.hasSuffix(" \($0)]") }) { suite.addTest(test) }
   }
   collect(all)
   write(["stage":"loaded", "testNames":suite.tests.map(\.name),"active":NSApp.isActive,"running":NSApp.isRunning])
   guard suite.tests.count==selected.count else { write(["error":"Missing selected tests","testNames":suite.tests.map(\.name)]); NSApp.terminate(nil); return }
   let observer=WindowFailureObserver()
   XCTestObservationCenter.shared.addTestObserver(observer)
   defer { XCTestObservationCenter.shared.removeTestObserver(observer) }
   suite.run()
   let run=suite.testRun!
   write(["stage":"finished","executed":run.executionCount,"failures":run.failureCount,"unexpected":run.unexpectedExceptionCount,"skipped":run.skipCount,"succeeded":run.hasSucceeded])
   NSApp.terminate(nil)
 }
 func write(_ value:[String:Any]) { let value = value.merging(["pid": ProcessInfo.processInfo.processIdentifier]) { old, _ in old }; let data=try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]);try! data.write(to:URL(fileURLWithPath:resultPath));print(String(decoding:data,as:UTF8.self));fflush(stdout) }
}
let args=CommandLine.arguments
let delegate=Delegate(bundlePath:args[1],resultPath:args[2])
let app=NSApplication.shared
app.delegate=delegate
app.setActivationPolicy(.regular)
app.run()
