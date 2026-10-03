import Foundation

struct GitHubCLIError: LocalizedError, Sendable {
  enum Blocker: Sendable, Equatable {
    case missingCLI, authentication, access

    var reason: String {
      switch self {
      case .missingCLI: "尚未安装或无法运行 GitHub CLI（gh），无法检查 PR。"
      case .authentication: "GitHub CLI 未登录或当前凭据已失效，无法检查 PR。"
      case .access: "当前 GitHub 凭据没有访问此 PR 所需的权限。"
      }
    }
    var question: String {
      switch self {
      case .missingCLI: "安装 GitHub CLI 后，是否在此任务中继续并恢复监控？"
      case .authentication: "希望使用哪个有权访问此 PR 的 GitHub 账户继续监控？"
      case .access: "能否为当前账户补齐此 PR 的访问权限，或选择有权限的账户？"
      }
    }
  }
  let message: String
  let blocker: Blocker?
  var errorDescription: String? { message }

  init(message: String, blocker: Blocker?) {
    self.message = message
    self.blocker = blocker
  }

  init(status: Int32, output: String) {
    message = output.isEmpty ? "GitHub CLI 操作失败。" : output
    let text = output.lowercased()
    if status == 4 {
      blocker = .authentication
    } else if status == 2 {
      blocker = nil
    } else if text.contains("rate limit") || text.contains("http 429")
      || text.contains("retry-after") || text.contains("abuse detection") {
      blocker = nil
    } else if text.contains("gh auth login") || text.contains("not logged into")
      || text.contains("bad credentials") || text.contains("http 401") {
      blocker = .authentication
    } else if text.contains("http 403") || text.contains("resource not accessible by")
      || text.contains("saml enforcement") || text.contains("saml sso") {
      blocker = .access
    } else {
      blocker = nil
    }
  }
}
