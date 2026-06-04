# ShellKit

Canonical async subprocess primitives for the shikki ecosystem.

Extracted from `Sources/ShiKit/Shell/` per `features/shellkit-hoist-2026-06-04.md` W1.
Leaf package: Foundation only. Zero shikki / ShiKit deps.

## Types

| Type | Role |
|------|------|
| `TimedShellExecutor` | Main `public actor` — run subprocesses with hard timeout, bounded concurrency, correct pipe drain, and NSTask kqueue race fix. Default `maxConcurrent: 4`. |
| `ShellExecutorProtocol` | `public protocol` — inject a mock in tests; production code uses `TimedShellExecutor`. |
| `ShellCommandResult` | `public struct` — immutable result carrying `exitCode`, `stdout: Data`, `stderr: Data`, `duration`. |
| `ShellError` | `public enum` — `.timeout(args:limit:)` or `.launchFailed(args:underlying:)`. |
| `AsyncSemaphore` | `public actor` — bounded-concurrency semaphore (H7 GCD fix). Used internally by `TimedShellExecutor`; available publicly for custom executors. |

## Usage

```swift
import ShellKit

let shell = TimedShellExecutor(maxConcurrent: 4)

// Run a command, get full result
let result = try await shell.run(["git", "status"], cwd: repoPath, timeout: 10)
print(result.stdoutString)

// Convenience — stdout as trimmed string (returns "" on failure)
let branch = await shell.runString(["git", "branch", "--show-current"], cwd: repoPath)

// Inject in tests
struct MockShell: ShellExecutorProtocol {
    func run(_ args: [String], cwd: String?, env: [String: String]?,
             timeout: TimeInterval, stdin: Data?) async throws -> ShellCommandResult {
        ShellCommandResult(exitCode: 0, stdout: Data("ok\n".utf8), stderr: Data(), duration: 0)
    }
}
```

## Why a separate package?

`ShellKit` is a leaf — it depends only on Foundation. This lets:
- Non-shikki tools (Kagami, Kotoba, external plugins) depend on it without pulling in the full ShiKit graph.
- The subprocess correctness fixes (H1/H3/H6/H7/W1.1/W1.2/W1.3) ship in a single auditable boundary.

## Correctness fixes included

| Fix | Root cause | Solution |
|-----|-----------|---------|
| H6 | Pipe deadlock >64KB | Parallel `Task.detached` drain before `waitUntilExit` |
| H7 | GCD 64-thread starvation | `AsyncSemaphore(limit: 4)` caps concurrent spawns |
| W1.1 | Actor mailbox starvation on `signal()` | `defer { Task.detached { semaphore.signal() } }` |
| W1.2 | FD_CLOEXEC missing on pipe write-ends | `fcntl(fd, F_SETFD, FD_CLOEXEC)` on all 4 pipe FDs |
| W1.3 | NSTask kqueue EVFILT_PROC race on fast children | `terminationHandler` set BEFORE `proc.run()` |
