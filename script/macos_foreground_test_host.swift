// Run only inside the explicitly enabled interactive XCTest host.
// Scheduling from an AppKit timer keeps asynchronous MainActor tests runnable.
import AppKit
import XCTest
final class Delegate: NSObject, NSApplicationDelegate {
 let resultPath: String
 let bundlePath: String
 var activationDeadline: Date?
 var launcher: NSWindow?
 let selected = ["testNativeActualMainMountsSidebarModalInsideExistingWindowAndInlineEditorBlurSaves", "testNativeActualMainPreparationCancelAndRetryActionsStayInExistingWindow", "testNativeRenameMountedBeforeWindowBecomesKeyFocusesOnlyOnce", "testNativeReturningFromFullBrowserMountsFocusedComposer", "testNativeTabThenImmediateSpaceActivatesTheNewSwitch", "testNativeRapidConfirmationKeysUseTheLatestSelection", "testNativeCancelledSettingsExitRestoresSearchAndBackKeyboardFocus"]
 init(bundlePath: String, resultPath: String) { self.bundlePath=bundlePath; self.resultPath=resultPath }
 func applicationDidFinishLaunching(_ notification: Notification) {
  let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 460,height: 180),styleMask: [.titled,.closable],backing: .buffered,defer: false)
  window.title = "ShipiOS 原生交互验收"
  let button = NSButton(title: "开始验收",target: self,action: #selector(startTests))
  button.frame = NSRect(x: 130,y: 65,width: 200,height: 40)
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
