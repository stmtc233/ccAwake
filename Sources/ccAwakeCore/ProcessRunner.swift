import Foundation

/// Runs a child process and safely captures its full stdout/stderr.
///
/// Both pipes are drained on background queues **before** `waitUntilExit()`
/// returns, so a child that writes more than the OS pipe buffer (~64KB) to a
/// pipe nobody is reading cannot deadlock: without concurrent draining the
/// child blocks on `write(2)` while the parent blocks forever in
/// `waitUntilExit()`.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data

        public init(status: Int32, stdout: Data, stderr: Data) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }

        public var stdoutString: String? {
            String(data: stdout, encoding: .utf8)
        }

        public var stderrString: String? {
            String(data: stderr, encoding: .utf8)
        }
    }

    /// Runs `executable` with `arguments`, returning the exit status and the
    /// fully captured output streams. Returns `nil` only if the process could
    /// not be launched.
    public static func run(executable: String, arguments: [String]) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain both pipes concurrently so neither can fill and block the child.
        let group = DispatchGroup()
        let collector = OutputCollector()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            collector.setStdout(data)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            collector.setStderr(data)
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return Result(
            status: process.terminationStatus,
            stdout: collector.stdout,
            stderr: collector.stderr
        )
    }

    /// Thread-safe accumulator for the two drain queues.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _stdout = Data()
        private var _stderr = Data()

        func setStdout(_ data: Data) {
            lock.lock(); _stdout = data; lock.unlock()
        }

        func setStderr(_ data: Data) {
            lock.lock(); _stderr = data; lock.unlock()
        }

        var stdout: Data {
            lock.lock(); defer { lock.unlock() }; return _stdout
        }

        var stderr: Data {
            lock.lock(); defer { lock.unlock() }; return _stderr
        }
    }
}
