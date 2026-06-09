import Foundation
import XCTest
@testable import ccAwakeCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdoutAndStatus() throws {
        let result = try XCTUnwrap(
            ProcessRunner.run(executable: "/bin/echo", arguments: ["hello"])
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testNonZeroStatusAndStderr() throws {
        // `sh -c 'echo oops >&2; exit 3'` exercises stderr capture + status.
        let result = try XCTUnwrap(
            ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"])
        )
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stderrString?.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
    }

    func testLargeOutputDoesNotDeadlock() throws {
        // Emit well over the ~64KB pipe buffer to both streams. Without
        // concurrent draining this would deadlock in waitUntilExit().
        let script = "yes ccAwake | head -n 200000; yes errstream | head -n 200000 >&2"
        let expectation = expectation(description: "process completes without hanging")
        var captured: ProcessRunner.Result?

        DispatchQueue.global().async {
            captured = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script])
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 20)
        let result = try XCTUnwrap(captured)
        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThan(result.stdout.count, 200_000)
        XCTAssertGreaterThan(result.stderr.count, 200_000)
    }

    func testReturnsNilWhenLaunchFails() {
        XCTAssertNil(ProcessRunner.run(executable: "/nonexistent/binary-xyz", arguments: []))
    }
}
