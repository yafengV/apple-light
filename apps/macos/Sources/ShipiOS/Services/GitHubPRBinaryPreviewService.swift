import CryptoKit
import Foundation

extension GitHubPRService {
  func binaryPreview(_ request: GitHubPRCodeRequest, code: GitHubPRCodeSnapshot,
    file: GitHubPRCodeFile, richPreviewEnabled: Bool) async throws -> GitHubPRRichPreview.Binary {
    guard code.files.contains(file),
      let kind = GitHubPRRichPreview.binaryKind(file, richPreviewEnabled: richPreviewEnabled),
      let url = request.pullRequest.validatedURL else {
      throw AgentFailure(message: "此文件不支持二进制预览。")
    }
    let before = try await codeIdentity(request)
    guard before == code.identity, before.head.lowercased() == request.head.lowercased() else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重试预览。")
    }
    let parts = url.pathComponents, repository = parts[1] + "/" + parts[2]
    var definitions = ["$owner:String!", "$name:String!"]
    var fields: [String] = []
    var variables: [String: JSONValue] = ["owner": .string(parts[1]), "name": .string(parts[2])]
    if file.kind != .added {
      definitions.append("$previous:String!")
      variables["previous"] = .string(before.base + ":" + (file.oldPath ?? file.path))
      fields.append("previous:object(expression:$previous) { __typename ... on Blob { oid byteSize } }")
    }
    if file.kind != .deleted {
      definitions.append("$current:String!")
      variables["current"] = .string(before.head + ":" + file.path)
      fields.append("current:object(expression:$current) { __typename ... on Blob { oid byteSize } }")
    }
    let data = try await discussionGraphQL("""
      query ShipiOSPRBinaryPreview(\(definitions.joined(separator: ","))) {
        repository(owner:$owner,name:$name) { nameWithOwner \(fields.joined(separator: "\n")) }
      }
      """, variables: variables, at: request.root)
    let node = data["repository"]
    guard node["nameWithOwner"].text?.lowercased() == repository.lowercased() else {
      throw AgentFailure(message: "PR 预览仓库不匹配。")
    }
    func object(_ name: String) throws -> (oid: String, size: Int) {
      let value = node[name]
      guard value["__typename"].text == "Blob", let oid = value["oid"].text,
        Self.validPreviewOID(oid), let size = value["byteSize"].int,
        (1...10_485_760).contains(size) else {
        throw AgentFailure(message: "PR 二进制文件超出预览范围或内容不可用。")
      }
      return (oid, size)
    }
    let prior = try file.kind == .added ? nil : object("previous")
    let current = try file.kind == .deleted ? nil : object("current")
    let oldBytes: Data?
    if let prior { oldBytes = try await previewBlob(prior.oid, size: prior.size,
      repository: repository, at: request.root) }
    else { oldBytes = nil }
    let newBytes: Data?
    if let current { newBytes = try await previewBlob(current.oid, size: current.size,
      repository: repository, at: request.root) }
    else { newBytes = nil }
    let after = try await codeIdentity(request)
    guard after == before else {
      throw GitHubPRCodeChanged(message: "PR 在读取文件预览时发生变化，请刷新差异后重试。")
    }
    try Task.checkCancellation()
    return .init(kind: kind, before: oldBytes, after: newBytes)
  }

  func previewBlob(_ oid: String, size: Int, repository: String, at root: URL) async throws -> Data {
    let output = try await run(["api", "--hostname", "github.com",
      "repos/\(repository)/git/blobs/\(oid)"], at: root, maxOutputBytes: 16_777_216)
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
    guard value["sha"].text?.lowercased() == oid.lowercased(), value["size"].int == size,
      value["encoding"].text == "base64", let source = value["content"].text else {
      throw AgentFailure(message: "GitHub 返回的二进制文件版本不匹配。")
    }
    let compact = source.split(whereSeparator: \.isWhitespace).joined()
    guard let bytes = Data(base64Encoded: compact), bytes.count == size,
      Self.gitBlobOID(bytes, length: oid.utf8.count).lowercased() == oid.lowercased() else {
      throw AgentFailure(message: "GitHub 返回的二进制文件内容校验失败。")
    }
    try Task.checkCancellation()
    return bytes
  }

  private static func validPreviewOID(_ oid: String) -> Bool {
    [40, 64].contains(oid.utf8.count) && oid.utf8.allSatisfy {
      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }
  }

  private static func gitBlobOID(_ bytes: Data, length: Int) -> String {
    let input = Data("blob \(bytes.count)\u{0}".utf8) + bytes
    if length == 64 { return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined() }
    return Insecure.SHA1.hash(data: input).map { String(format: "%02x", $0) }.joined()
  }
}
