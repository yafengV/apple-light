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
}
