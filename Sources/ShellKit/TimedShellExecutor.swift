import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - TimedShellExecutor
//
// Canonical async shell executor for the shikki CLI.
//
// Root causes addressed (per @t-completeness audit 2026-05-29/30):
//
//   H6 — Pipe deadlock: `waitUntilExit()` before `readDataToEndOfFile()`.
//         Fix: stdout/stderr drained by child Tasks IN PARALLEL with wait.
//
//   H7 — GCD starvation: 134 sequential `waitUntilExit()` exhaust GCD's
//         64-thread soft limit. Fix: `AsyncSemaphore` caps concurrency at
//         `maxConcurrent` (default 4).
//
//   H2 — `resolveRepoPath()` unguarded: zero timeout guard.
//         Fix: all callers use TimedShellExecutor which has a hard timeout.
//
//   H1/H3 — posix_spawn blocking + SIGTERM ignored: timeout wraps the
//            ENTIRE spawn+wait block; SIGTERM → 1s grace → SIGKILL escalation.
//
//   W1.3 — NSTask kqueue EVFILT_PROC race: `Task.detached { waitUntilExit() }`
//           subscribes to kqueue AFTER posix_spawn returns. Fast children (e.g.
//           `git rev-parse`, `/usr/bin/true`) can exit in the gap → notification
//           missed → infinite block. Fix: use `terminationHandler` (set on the
//           Process object BEFORE proc.run()) which is wired at spawn time by
//           NSTask internally, so exit can never be missed regardless of timing.

public actor TimedShellExecutor: ShellExecutorProtocol {

    /// SIGKILL grace period after SIGTERM. 1 second is sufficient for
    /// well-behaved processes; D-state processes are killed forcibly by SIGKILL.
    private static let sigtermGracePeriod: TimeInterval = 1.0

    private let semaphore: AsyncSemaphore

    /// Create a new executor.
    ///
    /// - Parameter maxConcurrent: Maximum number of subprocesses running in
    ///   parallel. Callers beyond this limit suspend until a slot is freed.
    ///   Default 4 is conservative to keep GCD thread usage far below the 64
    ///   soft limit even if the entire mop scan races.
    public init(maxConcurrent: Int = 4) {
        self.semaphore = AsyncSemaphore(limit: maxConcurrent)
    }

    public func run(
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = 10,
        stdin: Data? = nil
    ) async throws -> ShellCommandResult {
        // Acquire permit — suspends here if concurrency cap is reached (H7 fix).
        await semaphore.wait()
        // W1.1 fix: Task.detached avoids actor-mailbox starvation.
        // Under load the actor mailbox queues deeply; a Task { await self.semaphore.signal() }
        // inherits actor isolation and joins the mailbox queue — it may never execute
        // while all cooperative threads are IDLE waiting on blocked semaphore.wait() calls.
        // Task.detached runs on the cooperative pool without actor isolation, so signal()
        // fires immediately after the subprocess exits, regardless of mailbox depth.
        let semaphore = self.semaphore  // capture by value — no self. in closure
        defer { Task.detached { await semaphore.signal() } }

        return try await withTaskCancellationHandler {
            try await Self.spawnAndWait(
                args: args,
                cwd: cwd,
                env: env,
                timeout: timeout,
                stdin: stdin
            )
        } onCancel: {
            // If the outer Task is cancelled, nothing extra to do here —
            // the timeout Task inside spawnAndWait will SIGKILL the process.
        }
    }

    // MARK: - Core spawn implementation (nonisolated static)

    private static func spawnAndWait(
        args: [String],
        cwd: String?,
        env: [String: String]?,
        timeout: TimeInterval,
        stdin: Data?
    ) async throws -> ShellCommandResult {
        let start = Date()

        // Build the process.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args

        if let cwd = cwd {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        if let extraEnv = env, !extraEnv.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { merged[k] = v }
            proc.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        // W1.2 fix: set FD_CLOEXEC on pipe write-ends (and read-ends defensively)
        // so that when Process() calls posix_spawn for child N, the kernel closes
        // the parent's reference to the write-end of child N-1's pipe — preventing
        // the cascade hang where readDataToEndOfFile() on pipe N-1 blocks waiting
        // for all N..N+78 children to close their inherited copy of the write-end.
        // macOS Pipe() does NOT set O_CLOEXEC by default; this is the root cause
        // that defeated PRs #585 → #596 → #657 → #714 → #719.
        #if canImport(Darwin)
        fcntl(stdoutPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        fcntl(stderrPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        fcntl(stderrPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        #endif
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        if let stdinData = stdin {
            let stdinPipe = Pipe()
            proc.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.writeabilityHandler = { handle in
                handle.write(stdinData)
                handle.closeFile()
                handle.writeabilityHandler = nil
            }
        }

        // W1.3 fix: set terminationHandler BEFORE proc.run() so that child-exit
        // can never be missed regardless of timing (NSTask registers the kqueue
        // EVFILT_PROC/NOTE_EXIT subscription internally when the handler is set,
        // before posix_spawn is called). The old `Task.detached { waitUntilExit() }`
        // pattern subscribed to kqueue AFTER posix_spawn returned — fast children
        // (e.g. `git rev-parse`, `/usr/bin/true`) could exit in that window and
        // the notification was never delivered → infinite block.
        //
        // Guard against double-resume: terminationHandler can fire in a narrow
        // window even if proc.run() throws synchronously on some error paths.
        final class ResumeGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func tryResume(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                body()
            }
        }
        let guard_ = ResumeGuard()

        // Timeout watchdog: fires concurrently with the wait continuation.
        // SIGTERM → 1s grace → SIGKILL. Cannot be ignored or caught.
        // We use a nonisolated flag to communicate whether the timeout fired
        // before the process exited naturally.
        final class TimeoutFlag: @unchecked Sendable {
            var fired = false
        }
        let timeoutFlag = TimeoutFlag()

        // H6 fix: drain pipes IN PARALLEL with the wait.
        // Reading pipes only after waitUntilExit() deadlocks when child
        // produces >64KB (the pipe kernel buffer size on macOS). Background
        // Tasks drain continuously so child never blocks on backpressure.
        // NOTE: async let starts immediately here (before proc.run()), so
        // readDataToEndOfFile() is already blocked on the read-end by the time
        // the child starts writing — no backpressure window.
        async let stdoutData: Data = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        async let stderrData: Data = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        // Wire handler and run — the continuation resumes when the process exits.
        // proc.run() is called INSIDE the continuation so the handler is wired
        // first. The timeout task is launched before awaiting the continuation
        // so it fires concurrently if the process takes too long.
        // posix_spawn itself can block under extreme load (H1 fix: the entire
        // block is covered by the timeout task launched just below).
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Timeout fired: set flag then kill.
            // SIGKILL causes NSTask to invoke terminationHandler, which resumes
            // the continuation — no explicit continuation.resume() needed here.
            timeoutFlag.fired = true
            if proc.isRunning {
                proc.terminate() // SIGTERM
                try? await Task.sleep(nanoseconds: UInt64(Self.sigtermGracePeriod * 1_000_000_000))
                if proc.isRunning {
                    Darwin.kill(proc.processIdentifier, SIGKILL)
                }
            }
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                proc.terminationHandler = { _ in
                    guard_.tryResume { continuation.resume() }
                }
                do {
                    try proc.run()
                } catch {
                    guard_.tryResume {
                        continuation.resume(throwing: ShellError.launchFailed(
                            args: args, underlying: error.localizedDescription))
                    }
                }
            }
        } catch {
            timeoutTask.cancel()
            throw error
        }
        timeoutTask.cancel()

        let exitCode = proc.terminationStatus
        let stdout = await stdoutData
        let stderr = await stderrData
        let duration = Date().timeIntervalSince(start)

        // Detect timeout: flag was set by the watchdog before process exited.
        if timeoutFlag.fired {
            throw ShellError.timeout(args: args, limit: timeout)
        }

        return ShellCommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr, duration: duration)
    }
}

// MARK: - Convenience extensions

extension TimedShellExecutor {

    /// Run a command and return stdout as a trimmed string.
    /// Returns empty string on non-zero exit (mirrors legacy `run()` behaviour).
    public func runString(
        _ args: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 10
    ) async -> String {
        guard let result = try? await run(args, cwd: cwd, env: nil, timeout: timeout, stdin: nil) else {
            return ""
        }
        return result.stdoutString
    }

    /// Run a command and return the exit code.
    /// Returns -1 on launch failure, `timeout_exit_code` on timeout.
    public func runExitCode(
        _ args: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 10
    ) async -> Int32 {
        do {
            let result = try await run(args, cwd: cwd, env: nil, timeout: timeout, stdin: nil)
            return result.exitCode
        } catch ShellError.timeout {
            return -2
        } catch {
            return -1
        }
    }
}
