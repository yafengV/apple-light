import ApplicationServices
import Foundation

struct GlobalDictationInsertionPlan: Equatable {
  let value: String
  let caret: CFRange

  static func make(original: String, selection: CFRange, transcript: String) -> Self? {
    let units = Array(original.utf16)
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= units.count,
      selection.length <= units.count - selection.location,
      isUTF16Boundary(selection.location, in: units),
      isUTF16Boundary(selection.location + selection.length, in: units),
      let range = Range(NSRange(location: selection.location, length: selection.length), in: original)
    else { return nil }
    let value = original.replacingCharacters(in: range, with: transcript)
    return Self(value: value,
      caret: CFRange(location: selection.location + transcript.utf16.count, length: 0))
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value == rhs.value && lhs.caret.location == rhs.caret.location
      && lhs.caret.length == rhs.caret.length
  }

  private static func isUTF16Boundary(_ offset: Int, in units: [UInt16]) -> Bool {
    guard offset > 0, offset < units.count else { return true }
    return !(0xD800...0xDBFF).contains(units[offset - 1])
      || !(0xDC00...0xDFFF).contains(units[offset])
  }
}

/// Captures the editable control under the desktop cursor before recording starts.
@MainActor final class GlobalDictationTextTarget {
  private let element: AXUIElement
  private let originalValue: String
  private let originalSelection: CFRange

  private init(element: AXUIElement, value: String, selection: CFRange) {
    self.element = element
    originalValue = value
    originalSelection = selection
  }

  static func capture() throws -> GlobalDictationTextTarget {
    guard AXIsProcessTrusted() else {
      let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
      throw AgentFailure(message: "全局听写需要辅助功能权限，请在系统设置中允许 ShipiOS 控制此 Mac。")
    }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.5)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
      &focused) == .success, let focused,
      CFGetTypeID(focused) == AXUIElementGetTypeID() else {
      throw AgentFailure(message: "当前没有可听写的输入光标。")
    }
    let element = focused as! AXUIElement
    AXUIElementSetMessagingTimeout(element, 0.5)
    let role = string(element, kAXRoleAttribute as CFString)
    guard role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
      || role == kAXComboBoxRole as String else {
      throw AgentFailure(message: "当前光标不在可编辑的文本输入框中。")
    }
    guard let value = string(element, kAXValueAttribute as CFString),
      let selection = selection(element) else {
      throw AgentFailure(message: "当前输入框没有提供可安全插入的光标位置。")
    }
    var selectedTextWritable = DarwinBoolean(false)
    var valueWritable = DarwinBoolean(false)
    _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString,
      &selectedTextWritable)
    _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueWritable)
    guard selectedTextWritable.boolValue || valueWritable.boolValue else {
      throw AgentFailure(message: "当前输入框不允许通过辅助功能写入文字。")
    }
    guard GlobalDictationInsertionPlan.make(original: value, selection: selection,
      transcript: "") != nil else {
      throw AgentFailure(message: "当前输入框的光标位置无效。")
    }
    return GlobalDictationTextTarget(element: element, value: value, selection: selection)
  }

  func insert(_ transcript: String) throws {
    guard !transcript.isEmpty,
      let plan = GlobalDictationInsertionPlan.make(original: originalValue,
        selection: originalSelection, transcript: transcript) else { return }
    guard Self.string(element, kAXValueAttribute as CFString) == originalValue else {
      throw AgentFailure(message: "听写期间输入框内容已变化，未覆盖新的文字。")
    }
    let currentSelection = Self.selection(element)
    guard currentSelection?.location == originalSelection.location,
      currentSelection?.length == originalSelection.length else {
      throw AgentFailure(message: "听写期间光标已移动，未写入错误位置。")
    }
    var selectedTextWritable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString,
      &selectedTextWritable) == .success, selectedTextWritable.boolValue,
      AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
        transcript as CFString) == .success { return }
    guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString,
      plan.value as CFString) == .success else {
      throw AgentFailure(message: "当前输入框拒绝了听写文字。")
    }
    var caret = plan.caret
    if let axCaret = AXValueCreate(.cfRange, &caret) {
      _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
        axCaret)
    }
  }

  private static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
  }

  private static func selection(_ element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
      &value) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }
}
