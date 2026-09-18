import Foundation

struct ModelTokenUsage: Codable, Equatable {
  let inputTokens: Int
  let outputTokens: Int
  let totalTokens: Int
  let cachedInputTokens: Int?
  let reasoningOutputTokens: Int?

  init(
    inputTokens: Int, outputTokens: Int, totalTokens: Int? = nil,
    cachedInputTokens: Int? = nil, reasoningOutputTokens: Int? = nil
  ) {
    self.inputTokens = max(0, inputTokens)
    self.outputTokens = max(0, outputTokens)
    self.totalTokens = max(0, totalTokens ?? inputTokens + outputTokens)
    self.cachedInputTokens = cachedInputTokens.map { max(0, $0) }
    self.reasoningOutputTokens = reasoningOutputTokens.map { max(0, $0) }
  }

  init?(_ value: JSONValue) {
    let input = value["prompt_tokens"].int ?? value["input_tokens"].int
    let output = value["completion_tokens"].int ?? value["output_tokens"].int
    guard let input, let output, input >= 0, output >= 0 else { return nil }
    self.init(
      inputTokens: input, outputTokens: output,
      totalTokens: value["total_tokens"].int,
      cachedInputTokens: value["prompt_tokens_details"]["cached_tokens"].int
        ?? value["input_tokens_details"]["cached_tokens"].int,
      reasoningOutputTokens: value["completion_tokens_details"]["reasoning_tokens"].int
        ?? value["output_tokens_details"]["reasoning_tokens"].int)
  }

  var jsonValue: JSONValue {
    var values: [String: JSONValue] = [
      "input_tokens": .number(Double(inputTokens)),
      "output_tokens": .number(Double(outputTokens)),
      "total_tokens": .number(Double(totalTokens)),
    ]
    if let cachedInputTokens { values["cached_input_tokens"] = .number(Double(cachedInputTokens)) }
    if let reasoningOutputTokens {
      values["reasoning_output_tokens"] = .number(Double(reasoningOutputTokens))
    }
    return .object(values)
  }

  init?(stored value: JSONValue) {
    guard let input = value["input_tokens"].int, let output = value["output_tokens"].int else {
      return nil
    }
    self.init(
      inputTokens: input, outputTokens: output, totalTokens: value["total_tokens"].int,
      cachedInputTokens: value["cached_input_tokens"].int,
      reasoningOutputTokens: value["reasoning_output_tokens"].int)
  }
}

struct ModelUsageRecord: Identifiable, Equatable {
  let runID: String
  let taskID: String
  let taskTitle: String
  let projectTitle: String
  let model: String
  let reasoning: String
  let date: Date
  let duration: TimeInterval
  let usage: ModelTokenUsage
  var id: String { runID }

  var reasoningTitle: String {
    switch reasoning {
    case "": "服务默认"
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    default: reasoning
    }
  }
}

struct TaskModelUsage: Identifiable, Equatable {
  let taskID: String
  let taskTitle: String
  let projectTitle: String
  let usage: ModelTokenUsage
  let latestDate: Date
  let sessionCount: Int
  var id: String { taskID }
}

extension Collection where Element == ModelUsageRecord {
  var groupedByTask: [TaskModelUsage] {
    Dictionary(grouping: self, by: \.taskID).compactMap { taskID, records in
      guard let latest = records.max(by: { $0.date < $1.date }) else { return nil }
      return TaskModelUsage(
        taskID: taskID, taskTitle: latest.taskTitle, projectTitle: latest.projectTitle,
        usage: ModelTokenUsage(
          inputTokens: records.reduce(0) { $0 + $1.usage.inputTokens },
          outputTokens: records.reduce(0) { $0 + $1.usage.outputTokens },
          totalTokens: records.reduce(0) { $0 + $1.usage.totalTokens },
          cachedInputTokens: records.contains { $0.usage.cachedInputTokens != nil }
            ? records.compactMap(\.usage.cachedInputTokens).reduce(0, +) : nil,
          reasoningOutputTokens: records.contains { $0.usage.reasoningOutputTokens != nil }
            ? records.compactMap(\.usage.reasoningOutputTokens).reduce(0, +) : nil),
        latestDate: latest.date, sessionCount: records.count)
    }.sorted {
      $0.usage.totalTokens == $1.usage.totalTokens
        ? $0.latestDate > $1.latestDate : $0.usage.totalTokens > $1.usage.totalTokens
    }
  }
}

extension WorkspaceLibrary {
  var modelUsageRecords: [ModelUsageRecord] {
    chatRuns.compactMap { run in
      guard let result = run.result, let usage = ModelTokenUsage(stored: result["usage"]),
        let task = task(containing: run.id)
      else { return nil }
      return ModelUsageRecord(
        runID: run.id, taskID: task.id, taskTitle: task.title,
        projectTitle: projectTitle(task.project), model: run.request["model"].text ?? "未知模型",
        reasoning: run.request["reasoning_effort"].text ?? run.request["reasoning"].text ?? "",
        date: run.date, duration: max(0, (run.updatedAt - run.createdAt) / 1_000), usage: usage)
    }.sorted { $0.date > $1.date }
  }
}
