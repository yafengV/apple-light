import Foundation

struct SubagentElicitationRequest: Equatable, Identifiable {
  enum Choice: String, CaseIterable { case accept, acceptForSession = "accept_for_session", decline, cancel }
  let id: String
  let turnID: String
  let request: CodexElicitationRequest
  let choices: [Choice]
  let verificationURL: URL?
  let isTool: Bool
  let issue: String?
  init?(_ event: JSONValue) {
    guard event["type"].text == "elicitation_request",
      let token = event["shipios_elicitation"]["token"].text, let uuid = UUID(uuidString: token),
      let turn = event["shipios_elicitation"]["turnId"].text, !turn.isEmpty,
      event["turn_id"].text.map({ $0 == turn }) ?? true,
      case .array(let raw) = event["shipios_elicitation"]["choices"], !raw.isEmpty,
      raw.allSatisfy({ $0.text.flatMap(Choice.init(rawValue:)) != nil }),
      let server = event["server_name"].text, !server.isEmpty,
      let message = event["request"]["message"].text, !message.isEmpty,
      event["id"].text != nil || event["id"].int != nil else { return nil }
    var request: CodexElicitationRequest
    let issue: String?
    do { request = try CodexElicitationRequest.parse(event); issue = nil }
    catch {
      // Keep a refusal route for a captured request that cannot be rendered.
      // Unsafe URLs are never exposed as an action and invalid forms cannot submit.
      request = .init(serverName: server, requestID: event["id"], message: message, schema: .null)
      issue = error.localizedDescription
    }
    let choices = raw.compactMap { $0.text.flatMap(Choice.init(rawValue:)) }
    guard Set(choices).count == choices.count else { return nil }
    let isTool = event["request"]["_meta"]["codex_approval_kind"].text == "mcp_tool_call" && event["turn_id"].text != nil
    guard isTool || !choices.contains(.acceptForSession) else { return nil }
    id = token; turnID = turn; request.id = uuid; self.request = request
    self.choices = choices; self.isTool = isTool; self.issue = issue
    verificationURL = request.isURLRequest ? try? CodexElicitationRequest.verificationURL(event) : nil
  }
  func allows(_ choice: Choice, content: JSONValue?) -> Bool {
    guard choices.contains(choice) else { return false }
    if issue != nil { return [.decline, .cancel].contains(choice) && content == nil }
    if choice == .accept && !request.isURLRequest && !isTool { return content.map(request.validContent) == true }
    return content == nil
  }
}

struct SubagentElicitationStatus: Equatable {
  typealias Phase = SubagentApprovalStatus.Phase
  let turnID: String
  let revision: Int
  let phase: Phase
  let choice: SubagentElicitationRequest.Choice?
}
