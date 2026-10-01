import Foundation

extension MCPResourceActivity {
  /// Explicit metadata wins; malformed explicit metadata must not trigger a heuristic fallback.
  static func extract(_ result: JSONValue, serverName: String, toolName: String) -> [Self] {
    guard result["isError"].boolean != true else { return [] }
    if case .object(let metadata) = result["_meta"],
      metadata.keys.contains("openai/resourceActivities") {
      return parse(result) ?? []
    }
    if let drive = googleDrive(result, serverName: serverName, toolName: toolName) { return [drive] }
    let tool = normalized(toolName)
    if tool.hasSuffix("figma-create-new-file"), let figma = figmaCreatedFile(result) {
      return [figma]
    }
    if tool == "notion-fetch", let notion = notionFetchedPage(result) { return [notion] }
    if tool.hasSuffix("notion-create-pages") { return notionCreatedPages(result) }
    return []
  }

  static func extract(from output: String?, serverName: String, toolName: String) -> [Self] {
    guard let output, let result = try? JSONDecoder().decode(JSONValue.self,
      from: Data(output.utf8)) else { return [] }
    return extract(result, serverName: serverName, toolName: toolName)
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private static func text(_ value: JSONValue) -> String? {
    guard let raw = value.text?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty else { return nil }
    return String(raw.prefix(160))
  }

  private static func resource(url raw: String, title: String?, mimeType: String?,
    activity: TaskExternalSourceActivity, providerID: String? = nil) -> Self? {
    guard raw.utf8.count <= 4_096, raw.hasPrefix("https://") || raw.hasPrefix("http://"),
      let url = try? BrowserAddress.url(raw) else { return nil }
    let identifier = providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = identifier.flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
    return Self(id: String(id.prefix(256)),
      source: CodexWebSource(title: title ?? (url.host ?? url.absoluteString), url: url.absoluteString),
      mimeType: mimeType, activities: [activity], usesProviderID: identifier?.isEmpty == false)
  }

  private static let driveReadTools: Set<String> = Set((
    "export_file fetch find_document_text_range get_document get_document_comments " +
    "get_document_paragraph_range get_document_tables get_document_text get_file_metadata " +
    "get_presentation get_presentation_comments get_presentation_outline " +
    "get_presentation_tables get_presentation_text get_profile get_slide get_slide_thumbnail " +
    "get_spreadsheet_cells get_spreadsheet_comments get_spreadsheet_metadata " +
    "get_spreadsheet_range list_drives list_folder recent_documents search search_spreadsheet_rows"
    ).split(separator: " ").map(String.init))
  private static let driveWriteTools: Set<String> = Set((
    "batch_update_document batch_update_presentation batch_update_spreadsheet copy_file " +
    "create_file create_folder create_presentation_from_template delete_file " +
    "duplicate_sheet_in_new_spreadsheet import_document import_presentation " +
    "import_spreadsheet share_file").split(separator: " ").map(String.init))
  private static let driveCreateTools: Set<String> = ["copy_file", "create_file", "create_folder",
    "create_presentation_from_template", "duplicate_sheet_in_new_spreadsheet",
    "import_document", "import_presentation", "import_spreadsheet"]
  private static let driveURLFields = ["documentUrl", "document_url", "fileUrl", "file_url",
    "presentationUrl", "presentation_url", "spreadsheetUrl", "spreadsheet_url",
    "display_url", "url", "webViewLink", "web_view_link"]

  private static func googleDrive(_ result: JSONValue,
    serverName: String, toolName: String) -> Self? {
    let server = normalized(serverName)
    let rawTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTool = normalized(rawTool)
    let isDrive = server.contains("google-drive") || normalizedTool.hasPrefix("google-drive-")
      || normalizedTool.hasPrefix("google-drive-app-")
    guard isDrive else { return nil }
    let name: String
    if let prefix = rawTool.range(of: "^google[\\s_-]+drive(?:[\\s_-]+app)?[.\\s_-]+",
      options: [.regularExpression, .caseInsensitive]) {
      name = String(rawTool[prefix.upperBound...])
    } else if let dot = rawTool.lastIndex(of: "."),
      normalized(String(rawTool[..<dot])).contains("google-drive") {
      name = String(rawTool[rawTool.index(after: dot)...])
    } else { name = rawTool }
    let tool = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard tool != "delete_file", driveReadTools.contains(tool) || driveWriteTools.contains(tool) else {
      return nil
    }
    let structured = result["structuredContent"]
    guard case .object = structured,
      let url = driveURLFields.compactMap({ structured[$0].text }).first else { return nil }
    let title = [structured["title"], structured["display_title"], structured["name"],
      structured["properties"]["title"]].compactMap(text).first
    let mime = [structured["mimeType"], structured["mime_type"]].compactMap(text).first
    let activity: TaskExternalSourceActivity = driveReadTools.contains(tool) ? .read
      : driveCreateTools.contains(tool) ? .created : .updated
    return resource(url: url, title: title, mimeType: mime, activity: activity)
  }

  private static func textObjects(_ result: JSONValue) -> [JSONValue] {
    result["content"].items.compactMap { block in
      guard block["type"].text == "text", let value = block["text"].text,
        value.utf8.count <= 1_048_576 else { return nil }
      return try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
    }
  }

  private static func figmaCreatedFile(_ result: JSONValue) -> Self? {
    for object in textObjects(result) {
      guard let id = object["file_key"].text, !id.isEmpty,
        let url = object["file_url"].text else { continue }
      let message = object["message"].text ?? ""
      let pattern = try? NSRegularExpression(pattern: "^File\\s+\"(.+)\"\\s+created successfully\\.?$")
      let range = NSRange(message.startIndex..<message.endIndex, in: message)
      let title = pattern?.firstMatch(in: message, range: range)
        .flatMap { Range($0.range(at: 1), in: message) }.map { String(message[$0]) }
      return resource(url: url, title: title, mimeType: nil, activity: .created,
        providerID: id)
    }
    return nil
  }

  private static func notionFetchedPage(_ result: JSONValue) -> Self? {
    for object in textObjects(result) {
      guard object["metadata"]["type"].text == "page",
        let title = object["title"].text,
        let url = object["url"].text else { continue }
      return resource(url: url, title: text(.string(title)), mimeType: nil, activity: .read)
    }
    return nil
  }

  private static func notionCreatedPages(_ result: JSONValue) -> [Self] {
    for object in textObjects(result) {
      guard case .array(let pages) = object["pages"], pages.count <= 500 else { continue }
      let resources = pages.compactMap { page -> Self? in
        guard let id = page["id"].text, !id.isEmpty,
          let url = page["url"].text,
          let title = page["properties"]["title"].text else { return nil }
        return resource(url: url, title: text(.string(title)), mimeType: nil,
          activity: .created, providerID: id)
      }
      if resources.count == pages.count { return resources }
    }
    return []
  }
}
