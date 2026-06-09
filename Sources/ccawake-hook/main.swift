import Foundation
import ccAwakeCore

func writeError(_ message: String) {
    let data = Data(("ccawake-hook: \(message)\n").utf8)
    FileHandle.standardError.write(data)
}

let arguments = CommandLine.arguments.dropFirst()
guard let action = arguments.first, arguments.count == 1 else {
    writeError("usage: ccawake-hook touch|release")
    exit(2)
}

let input = FileHandle.standardInput.readDataToEndOfFile()

do {
    let payload = try ClaudeHookPayload.parse(input)
    let store = ClaudeSessionStore()

    switch action {
    case "touch":
        try store.touch(sessionID: payload.sessionID)
    case "release":
        try store.release(sessionID: payload.sessionID)
    default:
        writeError("unknown action \(action)")
        exit(2)
    }
} catch {
    // Hooks should not break the Claude Code workflow. Log and return success.
    writeError(error.localizedDescription)
    exit(0)
}
