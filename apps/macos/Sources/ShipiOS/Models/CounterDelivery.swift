import Foundation

enum CounterDeliveryPhase: String, Codable {
  case verifying, repairing, succeeded, failed, blocked, cancelled, interrupted
  var isActive: Bool { self == .verifying || self == .repairing }
  var title: String {
    switch self {
    case .verifying: "正在构建并验证计数器"
    case .repairing: "正在请求模型修复"
    case .succeeded: "计数器 UI 断言通过"
    case .failed: "验证未通过，可接管或重试"
    case .blocked: "验证受阻，构建与 UI 未运行"
    case .cancelled: "已停止验证"
    case .interrupted: "验证已中断，请检查工件后重试"
    }
  }
}

struct CounterDelivery: Codable, Equatable {
  let id: UUID
  let taskID: String
  let project: String
  let startedAt: Date
  var phase: CounterDeliveryPhase = .verifying
  var repairs = 0
  var modelRunIDs: [String] = []
  var verifications: [AgentRun] = []
  var message = ""
  var model = ""
  var serviceHost = ""
  var finishedAt: Date?
  var lastVerification: AgentRun? { verifications.last }
  static let maximumRepairs = 2
}

/// Only verified backend results end the loop. Model prose cannot declare success.
@MainActor enum CounterDeliveryOperation {
  static func run(_ initial: CounterDelivery, repairFailures: Bool,
    verify: () async throws -> AgentRun,
    repair: (String) async throws -> String,
    publish: (CounterDelivery) -> Bool
  ) async -> CounterDelivery {
    var state = initial
    func update() throws {
      try Task.checkCancellation()
      guard publish(state) else { throw CancellationError() }
    }
    do {
      while true {
        state.phase = .verifying; state.message = ""; try update()
        let result = try await verify()
        let actualProject = URL(fileURLWithPath: result.project).resolvingSymlinksInPath().standardizedFileURL
        let expectedProject = URL(fileURLWithPath: state.project).resolvingSymlinksInPath().standardizedFileURL
        guard result.kind == "verify_counter", actualProject == expectedProject, !result.isActive else {
          throw AgentFailure(message: "验证结果与当前工程或操作不匹配。")
        }
        state.verifications.append(result)
        try Task.checkCancellation()
        let summary = result.result?["testSummary"]
        let unchanged: Bool
        if case .array(let changes) = result.result?["changedInputs"] { unchanged = changes.isEmpty }
        else { unchanged = false }
        let passed = result.status == "succeeded" && result.result?["verification"].text == "passed"
          && unchanged && summary?["totalTestCount"].int == 1 && summary?["passedTests"].int == 1
          && ["failedTests", "skippedTests", "expectedFailures"].allSatisfy { summary?[$0].int == 0 }
        if passed { state.phase = .succeeded; break }
        state.message = result.result?["message"].text
          ?? result.result?["testSummary"]["testFailures"].items.first?["failureText"].text
          ?? "构建或固定 UI 断言未通过，请查看工件。"
        if result.result?["verification"].text == "blocked" {
          state.phase = .blocked
          break
        }
        guard repairFailures, result.status == "failed",
          state.repairs < CounterDelivery.maximumRepairs else {
          state.phase = result.status == "cancelled" ? .cancelled : .failed
          break
        }
        state.repairs += 1; state.phase = .repairing; try update()
        let prompt = """
          修复当前 HelloShipiOS 计数器验证失败（第 \(state.repairs)/2 轮）。
          只修改隔离工程中的 HelloShipiOSApp.swift，不修改固定 UI 测试、project 或 scheme。
          counter.value 初始 0，counter.increment 每次加 1，两次为 2，counter.reset 回到 0。
          失败：\(String(state.message.prefix(6000)))
          不自行重复运行修复循环，不提交 Git。完成改码后由应用重新执行固定验收。
          """
        state.modelRunIDs.append(try await repair(prompt))
        try update()
      }
    } catch {
      state.phase = error is CancellationError ? .cancelled : .failed
      state.message = error is CancellationError ? "操作已停止，代码与已有工件保留。" : error.localizedDescription
    }
    state.finishedAt = Date()
    _ = publish(state)
    return state
  }
}
