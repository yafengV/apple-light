import XCTest
@testable import ShipiOS

final class MCPResultDocumentTests: XCTestCase {
  func testMixedBlocksPreserveOrderMetadataAndPlainTextWithoutFetchingResources() {
    let raw = JSONValue.object(["content": .array([
      .object(["type": .string("text"), "text": .string("<script>alert(1)</script> **plain**")]),
      .object(["type": .string("image"), "data": .string("aW1hZ2U="), "mimeType": .string("image/png")]),
      .object(["type": .string("audio"), "data": .string("YXVkaW8="), "mimeType": .string("audio/wav")]),
      .object(["type": .string("resource_link"), "uri": .string("file:///outside/file"),
        "title": .string("Resource title"), "description": .string("Description")]),
      .object(["type": .string("resource"), "resource": .object([
        "uri": .string("custom://resource"), "mimeType": .string("text/plain"), "text": .string("embedded"),
        "annotations": .object(["priority": .number(0.8)])])]),
    ])]).pretty
    let result = MCPResultDocument.parse(raw)
    XCTAssertEqual(result.blocks.count, 5)
    XCTAssertEqual(result.blocks.map(\.id), Array(0..<5))
    XCTAssertEqual(result.blocks[0].content, .text("<script>alert(1)</script> **plain**"))
    XCTAssertEqual(result.blocks[1].content, .image(base64: "aW1hZ2U=", mime: "image/png"))
    XCTAssertEqual(result.blocks[2].content, .audio(base64: "YXVkaW8=", mime: "audio/wav"))
    XCTAssertEqual(result.blocks[3].content, .resourceLink(title: "Resource title", uri: "file:///outside/file", description: "Description"))
    XCTAssertEqual(result.blocks[4].content, .resource(uri: "custom://resource", mime: "text/plain", text: "embedded", blob: nil))
    XCTAssertTrue(result.blocks[4].annotations?.contains("0.8") == true)
  }

  func testStructuredContentRemovesOnlyIdenticalUnannotatedJSONText() {
    let result = MCPResultDocument.parse("""
      {"content":[{"type":"text","text":"{\\"value\\":1}"},
        {"type":"text","text":"Explanation"},
        {"type":"text","text":"{\\"value\\":1}","annotations":{"audience":["user"]}}],
       "structuredContent":{"value":1},"isError":true}
      """)
    XCTAssertEqual(result.blocks.count, 2)
    XCTAssertEqual(result.blocks.first?.content, .text("Explanation"))
    XCTAssertNotNil(result.blocks.last?.annotations)
    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.structured, JSONValue.object(["value": .number(1)]).pretty)
  }

  func testUnknownMalformedAndLegacyOutputRemainReadable() {
    XCTAssertEqual(MCPResultDocument.parse("Connection failed").blocks.first?.content, .text("Connection failed"))
    let result = MCPResultDocument.parse("""
      {"content":[{"type":"future","value":42},{"type":"image"},
        {"type":"resource","resource":{"uri":"data:test","blob":"AA=="}}]}
      """)
    if case .unknown(let raw) = result.blocks[0].content { XCTAssertTrue(raw.contains("42")) }
    else { XCTFail("Unknown result must remain visible") }
    if case .unknown = result.blocks[1].content {} else { XCTFail("Malformed image must remain visible") }
    XCTAssertEqual(result.blocks[2].content, .resource(uri: "data:test", mime: nil, text: nil, blob: "AA=="))
    XCTAssertFalse(MCPResultDocument.parse("{\"content\":\"bad content\"}").blocks.isEmpty)
    XCTAssertTrue(MCPResultDocument.parse("{\"content\":[]}").blocks.isEmpty)
  }

  func testImageDecodingUsesActualBytesAndBoundsThumbnailDimensions() throws {
    let data = try AttachmentFixture.png()
    let image = try MCPResultMedia.thumbnail(base64: data.base64EncodedString(), mime: "image/png", size: 1)
    XCTAssertEqual(image.width, 1)
    XCTAssertEqual(image.height, 1)
    XCTAssertThrowsError(try MCPResultMedia.thumbnail(base64: Data("not an image".utf8).base64EncodedString(), mime: "image/png", size: 640))
    XCTAssertThrowsError(try MCPResultMedia.decode("AA==", mime: "image/svg+xml", kind: "image"))
    XCTAssertThrowsError(try MCPResultMedia.decode("https://example.com/image.png", mime: "image/png", kind: "image"))
    XCTAssertThrowsError(try MCPResultMedia.decode(String(repeating: "A", count: 12 * 1_048_576), mime: "image/png", kind: "image"))
  }

  @MainActor func testAudioLoadSeekAndResetDoNotStartPlayback() throws {
    let playback = MCPAudioPlayback()
    let bytes = Self.silentWAV()
    XCTAssertEqual(try MCPResultMedia.decode(bytes.base64EncodedString(), mime: "audio/wav", kind: "audio"), bytes)
    playback.load(bytes)
    XCTAssertNil(playback.error)
    XCTAssertEqual(playback.duration, 0.125, accuracy: 0.005)
    XCTAssertFalse(playback.playing)
    playback.seek(10)
    XCTAssertEqual(playback.position, playback.duration)
    playback.seek(-1)
    XCTAssertEqual(playback.position, 0)
    playback.seek(.nan)
    XCTAssertEqual(playback.position, 0)
    playback.stop()
    playback.load(Data("invalid audio".utf8))
    XCTAssertNotNil(playback.error)
    XCTAssertEqual(playback.duration, 0)
    XCTAssertFalse(playback.playing)
  }

  private static func silentWAV() -> Data {
    var bytes = Data()
    func text(_ value: String) { bytes.append(Data(value.utf8)) }
    func short(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
    func long(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
    text("RIFF"); long(2036); text("WAVEfmt "); long(16); short(1); short(1)
    long(8000); long(16000); short(2); short(16); text("data"); long(2000)
    bytes.append(Data(repeating: 0, count: 2000))
    return bytes
  }
}
