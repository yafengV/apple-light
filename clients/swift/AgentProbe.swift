import Foundation

// Minimal native IPC client. It intentionally makes no model or credential requests.
guard CommandLine.arguments.count == 4 else {
    fputs("Usage: AgentProbe <agent-binary> <project-directory> <data-directory>\n", stderr)
    exit(2)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
process.arguments = ["--project", CommandLine.arguments[2], "--data-dir", CommandLine.arguments[3], "serve"]
let input = Pipe()
let output = Pipe()
process.standardInput = input
process.standardOutput = output
process.standardError = FileHandle.standardError

func send(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws {
    var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    data.append(10)
    try input.fileHandleForWriting.write(contentsOf: data)
}

do {
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
        if process.isRunning { process.terminate() }
    }
    try send(1, "initialize", ["protocolVersion": 1])
    var buffer = Data()
    var complete = false
    var succeeded = false
    while !complete {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let frame = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let message = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { continue }
            if let error = message["error"] { throw NSError(domain: "ShipiOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "RPC error: \(error)"]) }
            if let id = message["id"] as? Int, id == 1 {
                print("Connected to ShipiOS protocol v1")
                try send(2, "run.start", ["kind": "doctor"])
            }
            if let params = message["params"] as? [String: Any], let kind = params["kind"] as? String {
                print("Event: \(kind) #\(params["sequence"] ?? "?")")
                if kind == "run.completed" {
                    let payload = params["payload"] as? [String: Any]
                    succeeded = payload?["status"] as? String == "succeeded"
                    complete = true
                }
            }
        }
    }
    guard complete && succeeded else {
        throw NSError(domain: "ShipiOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Diagnostic did not complete successfully"])
    }
    print("Swift → Rust IPC diagnostic passed")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
