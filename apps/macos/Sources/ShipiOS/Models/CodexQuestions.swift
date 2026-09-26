import Foundation

struct CodexQuestionOption: Codable, Equatable, Sendable {
  let label: String
  let description: String
}

struct CodexQuestion: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let header: String
  let question: String
  let isOther: Bool
  let isSecret: Bool
  let options: [CodexQuestionOption]?

  enum CodingKeys: String, CodingKey { case id, header, question, isOther, isSecret, options }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    header = try values.decode(String.self, forKey: .header)
    question = try values.decode(String.self, forKey: .question)
    isOther = try values.decodeIfPresent(Bool.self, forKey: .isOther) ?? false
    isSecret = try values.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    options = try values.decodeIfPresent([CodexQuestionOption].self, forKey: .options)
  }
}

struct CodexQuestionRequest: Codable, Equatable, Identifiable, Sendable {
  enum Status: String, Codable, Sendable { case awaiting, answered, cancelled, expired }
  var id = UUID()
  let callID: String
  let turnID: String
  let questions: [CodexQuestion]
  let isBlocking: Bool
  var status: Status = .awaiting

  static func parse(_ event: JSONValue) throws -> Self {
    guard event["type"].text == "request_user_input",
      let callID = event["call_id"].text, !callID.isEmpty,
      let turnID = event["turn_id"].text, !turnID.isEmpty else {
      throw AgentFailure(message: "Codex 提问事件缺少回合标识。")
    }
    let questions = try event["questions"].decode([CodexQuestion].self)
    guard (1...3).contains(questions.count),
      Set(questions.map(\.id)).count == questions.count,
      questions.allSatisfy({ !$0.id.isEmpty && !$0.question.isEmpty }) else {
      throw AgentFailure(message: "Codex 返回了无效的问题列表。")
    }
    return Self(callID: callID, turnID: turnID, questions: questions,
      isBlocking: event["isBlocking"].boolean ?? true)
  }

  func validAnswers(_ answers: [String: [String]]) -> Bool {
    Set(answers.keys) == Set(questions.map(\.id)) && questions.allSatisfy { question in
      guard let values = answers[question.id], values.count == 1,
        let value = values.first?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty, value.utf8.count <= 4096 else { return false }
      return question.options?.contains(where: { $0.label == value }) == true
        || question.options == nil || question.isOther
    }
  }
}

struct CodexQuestionContext {
  let runID: String
  let taskID: String
  let request: CodexQuestionRequest
}

extension AgentRun {
  var codexQuestions: [CodexQuestionRequest] {
    (try? result?["codex_questions"].decode([CodexQuestionRequest].self)) ?? []
  }
}
