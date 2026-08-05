import XCTest
@testable import SiftRuntime

/// The handle is what makes "Durdur" real. Uses `/bin/sleep` rather than `claude` so the test
/// stays fast and offline.
final class ProcessHandleTests: XCTestCase {
    private func sleeper() -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        return p
    }

    func testTerminateKillsAnAdoptedProcess() throws {
        let handle = ProcessHandle()
        let process = sleeper()
        XCTAssertTrue(handle.adopt(process))
        try process.run()
        XCTAssertTrue(process.isRunning)

        handle.terminate()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning, "a cancelled run must not leave claude alive behind it")
    }

    func testCancellingBeforeLaunchRefusesTheProcess() {
        let handle = ProcessHandle()
        handle.terminate()   // the user hit stop in the gap before the process started
        XCTAssertFalse(handle.adopt(sleeper()),
                       "adopting after cancellation would spawn a process nothing can stop")
    }

    func testTerminateWithoutAProcessIsHarmless() {
        ProcessHandle().terminate()
    }
}
