import Foundation

struct FileEditorSession: Equatable {
  var baseText: String
  var text: String
  var saving = false
  var error: String?
  var changedOnDisk: String?

  var hasUnsavedChanges: Bool { !baseText.utf8.elementsEqual(text.utf8) }
}

struct FileEditorRecoveryDraft: Codable, Equatable {
  let baseText: String
  let text: String
  var context: FileEditorRecoveryContext? = nil
  var otherDrafts: [FileEditorRecoveryVersion]? = nil

  var version: FileEditorRecoveryVersion { .init(baseText: baseText, text: text, context: context) }
  var versions: [FileEditorRecoveryVersion] { [version] + (otherDrafts ?? []) }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.version == rhs.version && lhs.otherDrafts == rhs.otherDrafts
  }

  func selected(for context: FileEditorRecoveryContext?) -> FileEditorRecoveryVersion {
    versions.first { $0.context == context } ?? version
  }

  func merging(_ new: FileEditorRecoveryVersion, previousContexts: Set<FileEditorRecoveryContext>,
    legacySelection: FileEditorRecoveryVersion?) -> FileEditorRecoveryDraft {
    let retained = versions.filter {
      $0.context != new.context && !($0.context.map(previousContexts.contains) ?? false)
        && !(legacySelection?.context == nil && legacySelection == $0)
    }
    return .init(baseText: new.baseText, text: new.text, context: new.context,
      otherDrafts: retained.isEmpty ? nil : retained)
  }

  func removing(_ resolved: FileEditorRecoveryVersion) -> FileEditorRecoveryDraft? {
    let remaining = versions.filter { $0 != resolved }
    guard let first = remaining.first else { return nil }
    return .init(baseText: first.baseText, text: first.text, context: first.context,
      otherDrafts: remaining.count == 1 ? nil : Array(remaining.dropFirst()))
  }
}

/// Structured fields avoid ambiguities between a task ID and a file path that
/// happens to contain the same separators. The actual file remains the outer key.
struct FileEditorRecoveryContext: Codable, Hashable {
  enum Kind: String, Codable { case mainTree, mainFile, taskTree, taskFile }
  var kind: Kind
  var windowID: String? = nil
  var owner: String? = nil
  var filePath: String? = nil

  static func file(_ tab: WorkspaceContentTab, windowID: String? = nil) -> Self {
    .init(kind: windowID == nil ? .mainFile : .taskFile, windowID: windowID, owner: tab.owner,
      filePath: { if case .file(let path, _) = tab { return path }; return nil }())
  }
}

struct FileEditorRecoveryVersion: Codable, Equatable {
  let baseText: String
  let text: String
  let context: FileEditorRecoveryContext?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.context == rhs.context && lhs.baseText.utf8.elementsEqual(rhs.baseText.utf8)
      && lhs.text.utf8.elementsEqual(rhs.text.utf8)
  }
}
